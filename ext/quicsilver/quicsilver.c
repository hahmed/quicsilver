#include <ruby.h>
#include <ruby/thread.h>
#define QUIC_API_ENABLE_PREVIEW_FEATURES 1
#include "msquic.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

// Forward declarations
static VALUE quicsilver_drain_queue(VALUE self);

#if __linux__
#include <sys/epoll.h>
#elif __APPLE__ || __FreeBSD__
#include <sys/event.h>
#endif

static VALUE mQuicsilver;

// Custom execution: app owns the event loop, MsQuic spawns no threads
static QUIC_EVENTQ EventQ = -1;        // kqueue (macOS) / epoll (Linux)
static QUIC_EXECUTION* ExecContext = NULL;

#if __linux__
#include <sys/eventfd.h>
static int WakeFd = -1;  // eventfd for waking epoll
#endif
#define WAKE_IDENT 0xCAFE  // kqueue EVFILT_USER identifier (macOS only)

// --- GVL-free event buffer ---
// MsQuic callbacks write events here (no GVL needed).
// Ruby drains via Quicsilver.drain_queue (has GVL).

typedef struct {
    HQUIC connection;
    void* connection_ctx;
    VALUE client_obj;
    uint8_t event_type;  // EVT_RECEIVE..EVT_CONN_CLOSED
    uint64_t stream_id;
    char* data;          // heap copy, freed after drain
    size_t data_len;
    int early_data;
} BufferedEvent;

#define EVT_RECEIVE          0
#define EVT_RECEIVE_FIN      1
#define EVT_STREAM_RESET     2
#define EVT_STOP_SENDING     3
#define EVT_CONN_ESTABLISHED 4
#define EVT_CONN_CLOSED      5

static const char* EVENT_TYPE_NAMES[] = {
    "RECEIVE", "RECEIVE_FIN", "STREAM_RESET", "STOP_SENDING",
    "CONNECTION_ESTABLISHED", "CONNECTION_CLOSED"
};

#define EVENT_BUFFER_INITIAL 64
static BufferedEvent* EventBuffer = NULL;
static int EventBufferCount = 0;
static int EventBufferCap = 0;
static pthread_mutex_t EventBufferMutex = PTHREAD_MUTEX_INITIALIZER;

// Notification pipe: C signals [1], Ruby watches [0]
static int notify_pipe[2] = {-1, -1};

static void event_buffer_push(HQUIC conn, void* conn_ctx, VALUE client,
                              uint8_t type, uint64_t sid,
                              const char* data, size_t len, int early) {
    pthread_mutex_lock(&EventBufferMutex);
    if (EventBufferCount >= EventBufferCap) {
        EventBufferCap = EventBufferCap ? EventBufferCap * 2 : EVENT_BUFFER_INITIAL;
        EventBuffer = (BufferedEvent*)realloc(EventBuffer, EventBufferCap * sizeof(BufferedEvent));
    }
    BufferedEvent* ev = &EventBuffer[EventBufferCount++];
    ev->connection = conn;
    ev->connection_ctx = conn_ctx;
    ev->client_obj = client;
    ev->event_type = type;
    ev->stream_id = sid;
    ev->early_data = early;
    if (len > 0 && data) {
        ev->data = (char*)malloc(len);
        memcpy(ev->data, data, len);
        ev->data_len = len;
    } else {
        ev->data = NULL;
        ev->data_len = 0;
    }
    pthread_mutex_unlock(&EventBufferMutex);

    // Signal Ruby that events are ready
    if (notify_pipe[1] != -1) {
        write(notify_pipe[1], ".", 1);
    }
}

// Wake the event loop — signal the notification pipe so bridge.wait returns.
static void
wake_event_loop(void)
{
    if (notify_pipe[1] != -1) {
        write(notify_pipe[1], ".", 1);
    }
}

// Global MSQUIC API table
static const QUIC_API_TABLE* MsQuic = NULL;

// Global registration handle
static HQUIC Registration = NULL;

// Registration configuration
static const QUIC_REGISTRATION_CONFIG RegConfig = { "quicsilver", QUIC_EXECUTION_PROFILE_LOW_LATENCY };

// Connection state tracking
typedef struct {
    int connected;
    int failed;
    QUIC_STATUS error_status;
    uint64_t error_code;
    VALUE client_obj;  // Ruby client object (Qnil for server connections)
} ConnectionContext;

// Listener state tracking
typedef struct {
    int started;
    int stopped;
    int failed;
    QUIC_STATUS error_status;
    HQUIC Configuration;
} ListenerContext;

// Stream state tracking
typedef struct {
    HQUIC connection;
    void* connection_ctx;  // ConnectionContext pointer (for building connection_data)
    VALUE client_obj;      // Ruby client object (copied from connection context)
    uint64_t stream_id;    // QUIC stream ID, cached once after StreamStart
    int started;
    int shutdown;
    int early_data;        // Set when stream received 0-RTT data
    QUIC_STATUS error_status;
} StreamContext;

// Pending stream priorities — set from Ruby threads, applied on MsQuic event thread.
// Simple array-based storage (max 256 pending). Key = stream handle, value = priority + 1.
#define MAX_PENDING_PRIORITIES 256
static struct { HQUIC stream; uint16_t priority_plus_one; } PendingPriorities[MAX_PENDING_PRIORITIES];
static int PendingPriorityCount = 0;

// rb_protect wrapper — catches Ruby exceptions so they don't longjmp
// through MsQuic callback frames (which would corrupt MsQuic state).
// All Ruby object construction AND the funcall happen inside rb_protect.
struct dispatch_ruby_args {
    HQUIC connection;
    void* connection_ctx;
    VALUE client_obj;
    const char* event_type;
    uint64_t stream_id;
    const char* data;
    size_t data_len;
    int early_data;
};

static VALUE
dispatch_ruby_body(VALUE arg)
{
    struct dispatch_ruby_args* a = (struct dispatch_ruby_args*)arg;
    VALUE data_str = (a->data && a->data_len > 0) ? rb_str_new(a->data, a->data_len) : rb_str_new("", 0);

    if (NIL_P(a->client_obj)) {
        VALUE server_class = rb_const_get_at(mQuicsilver, rb_intern("Server"));
        if (rb_class_real(CLASS_OF(server_class)) == rb_cClass) {
            VALUE connection_data = rb_ary_new2(2);
            rb_ary_push(connection_data, ULL2NUM((uintptr_t)a->connection));
            rb_ary_push(connection_data, ULL2NUM((uintptr_t)a->connection_ctx));
            VALUE argv[5] = {
                connection_data,
                ULL2NUM(a->stream_id),
                rb_str_new_cstr(a->event_type),
                data_str,
                a->early_data ? Qtrue : Qfalse
            };
            rb_funcallv(server_class, rb_intern("handle_stream"), 5, argv);
        }
    } else {
        if (RB_TYPE_P(a->client_obj, T_OBJECT)) {
            VALUE argv[4] = {
                ULL2NUM(a->stream_id),
                rb_str_new_cstr(a->event_type),
                data_str,
                a->early_data ? Qtrue : Qfalse
            };
            rb_funcallv(a->client_obj, rb_intern("handle_stream_event"), 4, argv);
        }
    }

    return Qnil;
}

// Dispatch event to Ruby — entire body wrapped in rb_protect so no Ruby call
// (object construction or funcall) can longjmp through MsQuic callback frames.
static void
dispatch_to_ruby(HQUIC connection, void* connection_ctx, VALUE client_obj,
                 const char* event_type, uint64_t stream_id,
                 const char* data, size_t data_len, int early_data)
{
    struct dispatch_ruby_args args;
    args.connection = connection;
    args.connection_ctx = connection_ctx;
    args.client_obj = client_obj;
    args.event_type = event_type;
    args.stream_id = stream_id;
    args.data = data;
    args.data_len = data_len;
    args.early_data = early_data;

    int state = 0;
    rb_protect(dispatch_ruby_body, (VALUE)&args, &state);
    if (state) {
        rb_set_errinfo(Qnil);
        fprintf(stderr, "Quicsilver: exception in callback\n");
    }
}

// Legacy poll — now just drains the event buffer.
// MsQuic drives itself on its own thread pool.
static VALUE
quicsilver_poll(VALUE self)
{
    return quicsilver_drain_queue(self);
}



QUIC_STATUS
StreamCallback(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event)
{
    StreamContext* ctx = (StreamContext*)Context;

    if (ctx == NULL) {
        return QUIC_STATUS_SUCCESS;
    }

    // Lazily cache the QUIC stream ID on first callback.
    // Can't do this at StreamStart — MsQuic defers ID assignment with FLAG_NONE
    // until data is sent. By the first callback the ID is always assigned.
    if (ctx->stream_id == UINT64_MAX) {
        uint32_t id_len = sizeof(ctx->stream_id);
        MsQuic->GetParam(Stream, QUIC_PARAM_STREAM_ID, &id_len, &ctx->stream_id);
    }

    // Apply pending priority on the event loop thread (safe context for SetParam)
    for (int i = 0; i < PendingPriorityCount; i++) {
        if (PendingPriorities[i].stream == Stream) {
            uint16_t priority = PendingPriorities[i].priority_plus_one - 1;
            // Remove by swapping with last
            PendingPriorities[i] = PendingPriorities[--PendingPriorityCount];
            MsQuic->SetParam(Stream, QUIC_PARAM_STREAM_PRIORITY, sizeof(priority), &priority);
            break;
        }
    }

    switch (Event->Type) {
        case QUIC_STREAM_EVENT_RECEIVE: {
            int has_fin = (Event->RECEIVE.Flags & QUIC_RECEIVE_FLAG_FIN) != 0;

            // Track 0-RTT early data for replay protection
            if (Event->RECEIVE.Flags & QUIC_RECEIVE_FLAG_0_RTT) {
                ctx->early_data = 1;
            }

            if (Event->RECEIVE.BufferCount == 0 && has_fin) {
                // Empty FIN — headers-only request/response with no body
                event_buffer_push(ctx->connection, ctx->connection_ctx, ctx->client_obj,
                    EVT_RECEIVE_FIN, ctx->stream_id, (const char*)&Stream, sizeof(HQUIC), ctx->early_data);
                break;
            }

            if (Event->RECEIVE.BufferCount > 0) {
                uint8_t evt = has_fin ? EVT_RECEIVE_FIN : EVT_RECEIVE;

                size_t total_data_len = 0;
                for (uint32_t b = 0; b < Event->RECEIVE.BufferCount; b++) {
                    total_data_len += Event->RECEIVE.Buffers[b].Length;
                }

                int is_client = !NIL_P(ctx->client_obj);

                if (is_client || has_fin) {
                    // Client: always prepend [stream_handle(8)] so Ruby can map
                    // handle→stream_id from any event (needed for GOAWAY).
                    // Server FIN: also prepends handle (existing behavior).
                    size_t total_len = sizeof(HQUIC) + total_data_len;
                    char* combined = (char*)malloc(total_len);
                    if (combined != NULL) {
                        memcpy(combined, &Stream, sizeof(HQUIC));
                        size_t offset = sizeof(HQUIC);
                        for (uint32_t b = 0; b < Event->RECEIVE.BufferCount; b++) {
                            memcpy(combined + offset, Event->RECEIVE.Buffers[b].Buffer, Event->RECEIVE.Buffers[b].Length);
                            offset += Event->RECEIVE.Buffers[b].Length;
                        }
                        event_buffer_push(ctx->connection, ctx->connection_ctx, ctx->client_obj, evt, ctx->stream_id, combined, total_len, has_fin ? ctx->early_data : 0);
                        free(combined);
                    }
                } else if (Event->RECEIVE.BufferCount == 1) {
                    // Server non-FIN: raw data without handle prefix
                    event_buffer_push(ctx->connection, ctx->connection_ctx, ctx->client_obj, evt, ctx->stream_id,
                        (const char*)Event->RECEIVE.Buffers[0].Buffer, Event->RECEIVE.Buffers[0].Length, 0);
                } else {
                    // Server non-FIN with multiple buffers: combine without handle prefix
                    char* combined = (char*)malloc(total_data_len);
                    if (combined != NULL) {
                        size_t offset = 0;
                        for (uint32_t b = 0; b < Event->RECEIVE.BufferCount; b++) {
                            memcpy(combined + offset, Event->RECEIVE.Buffers[b].Buffer, Event->RECEIVE.Buffers[b].Length);
                            offset += Event->RECEIVE.Buffers[b].Length;
                        }
                        event_buffer_push(ctx->connection, ctx->connection_ctx, ctx->client_obj, evt, ctx->stream_id, combined, total_data_len, 0);
                        free(combined);
                    }
                }
            }
            break;
        }
        case QUIC_STREAM_EVENT_SEND_COMPLETE:
            // Free the send buffer that was allocated in quicsilver_send_stream
            if (Event->SEND_COMPLETE.ClientContext != NULL) {
                free(Event->SEND_COMPLETE.ClientContext);
            }
            break;
        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
            ctx->shutdown = 1;
            free(ctx);
            MsQuic->SetCallbackHandler(Stream, (void*)StreamCallback, NULL);
            if (Event->SHUTDOWN_COMPLETE.AppCloseInProgress == FALSE) {
                MsQuic->StreamClose(Stream);
            }
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_ABORTED: {
            // Peer sent RESET_STREAM — pack [stream_handle(8)][error_code(8)]
            uint64_t error_code = Event->PEER_SEND_ABORTED.ErrorCode;
            char combined[sizeof(HQUIC) + sizeof(uint64_t)];
            memcpy(combined, &Stream, sizeof(HQUIC));
            memcpy(combined + sizeof(HQUIC), &error_code, sizeof(uint64_t));
            event_buffer_push(ctx->connection, ctx->connection_ctx, ctx->client_obj, EVT_STREAM_RESET, ctx->stream_id, combined, sizeof(combined), 0);
            break;
        }
        case QUIC_STREAM_EVENT_PEER_RECEIVE_ABORTED: {
            // Peer sent STOP_SENDING — pack [stream_handle(8)][error_code(8)]
            uint64_t error_code = Event->PEER_RECEIVE_ABORTED.ErrorCode;
            char combined[sizeof(HQUIC) + sizeof(uint64_t)];
            memcpy(combined, &Stream, sizeof(HQUIC));
            memcpy(combined + sizeof(HQUIC), &error_code, sizeof(uint64_t));
            event_buffer_push(ctx->connection, ctx->connection_ctx, ctx->client_obj, EVT_STOP_SENDING, ctx->stream_id, combined, sizeof(combined), 0);
            break;
        }
    }

    return QUIC_STATUS_SUCCESS;
}

// Connection callback
static QUIC_STATUS QUIC_API
ConnectionCallback(HQUIC Connection, void* Context, QUIC_CONNECTION_EVENT* Event)
{
    ConnectionContext* ctx = (ConnectionContext*)Context;
    HQUIC Stream;
    StreamContext* stream_ctx;
    
    if (ctx == NULL) {
        return QUIC_STATUS_SUCCESS;
    }
    
    switch (Event->Type) {
        case QUIC_CONNECTION_EVENT_CONNECTED:
            ctx->connected = 1;
            ctx->failed = 0;
            // Notify Ruby about new connection - pass ctx pointer for building connection_data
            event_buffer_push(Connection, ctx, ctx->client_obj, EVT_CONN_ESTABLISHED, 0, (const char*)&Connection, sizeof(HQUIC), 0);
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
            ctx->connected = 0;
            ctx->failed = 1;
            ctx->error_status = Event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status;
            ctx->error_code = Event->SHUTDOWN_INITIATED_BY_TRANSPORT.ErrorCode;
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
            ctx->connected = 0;
            ctx->failed = 1;
            ctx->error_status = QUIC_STATUS_SUCCESS; // Peer initiated, not an error
            ctx->error_code = Event->SHUTDOWN_INITIATED_BY_PEER.ErrorCode;
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
            ctx->connected = 0;
            // Buffer the event — ctx cleanup deferred to drain_queue.
            // Can't call dispatch_to_ruby here (no GVL on MsQuic thread).
            event_buffer_push(Connection, ctx, ctx->client_obj, EVT_CONN_CLOSED, 0, (const char*)&Connection, sizeof(HQUIC), 0);
            // NOTE: ctx is NOT freed here. drain_queue handles cleanup
            // after dispatching CONNECTION_CLOSED to Ruby.
            break;
         case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED:
            // Client opened a stream
            Stream = Event->PEER_STREAM_STARTED.Stream;
            stream_ctx = (StreamContext*)malloc(sizeof(StreamContext));
            if (stream_ctx != NULL) {
                stream_ctx->connection = Connection;
                stream_ctx->connection_ctx = ctx;  // Store connection context pointer
                stream_ctx->client_obj = ctx->client_obj;  // Copy from connection context
                stream_ctx->started = 1;
                stream_ctx->shutdown = 0;
                stream_ctx->stream_id = UINT64_MAX;  // Lazily resolved on first callback
                stream_ctx->early_data = 0;
                stream_ctx->error_status = QUIC_STATUS_SUCCESS;

                // Set the stream callback handler to handle data events
                MsQuic->SetCallbackHandler(Stream, (void*)StreamCallback, stream_ctx);
            } else {
                MsQuic->StreamClose(Stream);
            }
         break; 
        default:
            break;
    }
    
    return QUIC_STATUS_SUCCESS;
}

// Listener callback to handle incoming connections
static QUIC_STATUS QUIC_API
ListenerCallback(HQUIC Listener, void* Context, QUIC_LISTENER_EVENT* Event)
{
    ListenerContext* ctx = (ListenerContext*)Context;
    ConnectionContext* conn_ctx;
    
    if (ctx == NULL) {
        return QUIC_STATUS_SUCCESS;
    }
    
    switch (Event->Type) {
        case QUIC_LISTENER_EVENT_NEW_CONNECTION:
            // Create a connection context for the new connection
            conn_ctx = (ConnectionContext*)malloc(sizeof(ConnectionContext));
            if (conn_ctx != NULL) {
                conn_ctx->connected = 0;
                conn_ctx->failed = 0;
                conn_ctx->error_status = QUIC_STATUS_SUCCESS;
                conn_ctx->error_code = 0;
                conn_ctx->client_obj = Qnil;  // Server connections have no client object

                // Set the connection callback
                MsQuic->SetCallbackHandler(Event->NEW_CONNECTION.Connection, (void*)ConnectionCallback, conn_ctx);

                // Accept the new connection with the server configuration
                QUIC_STATUS Status = MsQuic->ConnectionSetConfiguration(Event->NEW_CONNECTION.Connection, ctx->Configuration);
                if (QUIC_FAILED(Status)) {
                    free(conn_ctx);
                    return Status;
                }

            } else {
                // Reject the connection if we can't allocate context
                return QUIC_STATUS_OUT_OF_MEMORY;
            }
            break;
            
        case QUIC_LISTENER_EVENT_STOP_COMPLETE:
            ctx->stopped = 1;
            break;
            
        default:
            break;
    }
    
    return QUIC_STATUS_SUCCESS;
}

// Initialize MSQUIC
static VALUE
quicsilver_open(VALUE self)
{
    QUIC_STATUS Status;
    
    // Check if already initialized
    if (MsQuic != NULL) {
        return Qtrue;
    }
    
    // Open a handle to the library and get the API function table
    if (QUIC_FAILED(Status = MsQuicOpenVersion(2, (const void**)&MsQuic))) {
        rb_raise(rb_eRuntimeError, "MsQuicOpenVersion failed, 0x%x!", Status);
        return Qfalse;
    }

    // MsQuic thread pool mode: no custom execution context.
    // MsQuic creates its own threads and fires callbacks there.
    // Callbacks write to the ring buffer (no GVL needed).
    // Ruby drains via drain_queue (has GVL).
    if (QUIC_FAILED(Status = MsQuic->RegistrationOpen(&RegConfig, &Registration))) {
        MsQuicClose(MsQuic);
        MsQuic = NULL;
        rb_raise(rb_eRuntimeError, "RegistrationOpen failed, 0x%x!", Status);
        return Qfalse;
    }

    return Qtrue;
}

// Create a QUIC configuration (for client connections)
static VALUE
quicsilver_create_configuration(VALUE self, VALUE unsecure)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized. Call Quicsilver.open_connection first.");
        return Qnil;
    }
    
    QUIC_STATUS Status;
    HQUIC Configuration = NULL;
    
    // Basic settings
    QUIC_SETTINGS Settings = {0};
    Settings.IdleTimeoutMs = 10000; // 10 second idle timeout to match server
    Settings.IsSet.IdleTimeoutMs = TRUE;
    
    // Simple ALPN for now - Ruby can customize this later
    QUIC_BUFFER Alpn = { sizeof("h3") - 1, (uint8_t*)"h3" };
    
    // Create configuration
    if (QUIC_FAILED(Status = MsQuic->ConfigurationOpen(Registration, &Alpn, 1, &Settings, sizeof(Settings), NULL, &Configuration))) {
        rb_raise(rb_eRuntimeError, "ConfigurationOpen failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Set up credentials
    QUIC_CREDENTIAL_CONFIG CredConfig = {0};
    CredConfig.Type = QUIC_CREDENTIAL_TYPE_NONE;
    CredConfig.Flags = QUIC_CREDENTIAL_FLAG_CLIENT;
    
    if (RTEST(unsecure)) {
        CredConfig.Flags |= QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION;
    }
    
    if (QUIC_FAILED(Status = MsQuic->ConfigurationLoadCredential(Configuration, &CredConfig))) {
        MsQuic->ConfigurationClose(Configuration);
        rb_raise(rb_eRuntimeError, "ConfigurationLoadCredential failed, 0x%x!", Status);
        return Qnil;
    }

    // Return the configuration handle as a Ruby integer (pointer)
    return ULL2NUM((uintptr_t)Configuration);
}

// Create a QUIC server configuration
static VALUE
quicsilver_create_server_configuration(VALUE self, VALUE config_hash)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized. Call Quicsilver.open_connection first.");
        return Qnil;
    }
    VALUE cert_file_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("cert_file")));
    VALUE key_file_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("key_file")));
    VALUE idle_timeout_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("idle_timeout_ms")));
    VALUE server_resumption_level_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("server_resumption_level")));
    VALUE max_concurrent_requests_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("max_concurrent_requests")));
    VALUE max_unidirectional_streams_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("max_unidirectional_streams")));
    VALUE alpn_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("alpn")));
    VALUE stream_receive_window_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("stream_receive_window")));
    VALUE stream_receive_buffer_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("stream_receive_buffer")));
    VALUE connection_flow_control_window_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("connection_flow_control_window")));
    VALUE pacing_enabled_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("pacing_enabled")));
    VALUE send_buffering_enabled_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("send_buffering_enabled")));
    VALUE initial_rtt_ms_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("initial_rtt_ms")));
    VALUE initial_window_packets_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("initial_window_packets")));
    VALUE max_ack_delay_ms_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("max_ack_delay_ms")));
    VALUE keep_alive_interval_ms_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("keep_alive_interval_ms")));
    VALUE congestion_control_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("congestion_control_algorithm")));
    VALUE migration_enabled_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("migration_enabled")));
    VALUE disconnect_timeout_ms_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("disconnect_timeout_ms")));
    VALUE handshake_idle_timeout_ms_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("handshake_idle_timeout_ms")));

    QUIC_STATUS Status;
    HQUIC Configuration = NULL;

    const char* cert_path = StringValueCStr(cert_file_val);
    const char* key_path = StringValueCStr(key_file_val);
    uint32_t idle_timeout_ms = NUM2INT(idle_timeout_val);
    uint32_t server_resumption_level = NUM2INT(server_resumption_level_val);
    uint32_t max_concurrent_requests = NUM2INT(max_concurrent_requests_val);
    uint32_t max_unidirectional_streams = NUM2INT(max_unidirectional_streams_val);
    const char* alpn_str = StringValueCStr(alpn_val);
    uint32_t stream_receive_window = NUM2UINT(stream_receive_window_val);
    uint32_t stream_receive_buffer = NUM2UINT(stream_receive_buffer_val);
    uint32_t connection_flow_control_window = NUM2UINT(connection_flow_control_window_val);
    uint8_t pacing_enabled = (uint8_t)NUM2INT(pacing_enabled_val);
    uint8_t send_buffering_enabled = (uint8_t)NUM2INT(send_buffering_enabled_val);
    uint32_t initial_rtt_ms = NUM2UINT(initial_rtt_ms_val);
    uint32_t initial_window_packets = NUM2UINT(initial_window_packets_val);
    uint32_t max_ack_delay_ms = NUM2UINT(max_ack_delay_ms_val);
    uint32_t keep_alive_interval_ms = NUM2UINT(keep_alive_interval_ms_val);
    uint16_t congestion_control = (uint16_t)NUM2INT(congestion_control_val);
    uint8_t migration_enabled = (uint8_t)NUM2INT(migration_enabled_val);
    uint32_t disconnect_timeout_ms = NUM2UINT(disconnect_timeout_ms_val);
    uint64_t handshake_idle_timeout_ms = NUM2ULL(handshake_idle_timeout_ms_val);

    QUIC_SETTINGS Settings = {0};
    Settings.IdleTimeoutMs = idle_timeout_ms;
    Settings.IsSet.IdleTimeoutMs = TRUE;
    Settings.ServerResumptionLevel = server_resumption_level;
    Settings.IsSet.ServerResumptionLevel = TRUE;
    Settings.PeerBidiStreamCount = max_concurrent_requests;
    Settings.IsSet.PeerBidiStreamCount = TRUE;
    Settings.PeerUnidiStreamCount = max_unidirectional_streams;
    Settings.IsSet.PeerUnidiStreamCount = TRUE;

    // Flow control / backpressure settings
    Settings.StreamRecvWindowDefault = stream_receive_window;
    Settings.IsSet.StreamRecvWindowDefault = TRUE;
    Settings.StreamRecvBufferDefault = stream_receive_buffer;
    Settings.IsSet.StreamRecvBufferDefault = TRUE;
    Settings.ConnFlowControlWindow = connection_flow_control_window;
    Settings.IsSet.ConnFlowControlWindow = TRUE;

    // Throughput settings
    Settings.PacingEnabled = pacing_enabled;
    Settings.IsSet.PacingEnabled = TRUE;
    Settings.SendBufferingEnabled = send_buffering_enabled;
    Settings.IsSet.SendBufferingEnabled = TRUE;
    Settings.InitialRttMs = initial_rtt_ms;
    Settings.IsSet.InitialRttMs = TRUE;
    Settings.InitialWindowPackets = initial_window_packets;
    Settings.IsSet.InitialWindowPackets = TRUE;
    Settings.MaxAckDelayMs = max_ack_delay_ms;
    Settings.IsSet.MaxAckDelayMs = TRUE;

    // Connection management
    Settings.KeepAliveIntervalMs = keep_alive_interval_ms;
    Settings.IsSet.KeepAliveIntervalMs = TRUE;
    Settings.CongestionControlAlgorithm = congestion_control;
    Settings.IsSet.CongestionControlAlgorithm = TRUE;
    Settings.MigrationEnabled = migration_enabled;
    Settings.IsSet.MigrationEnabled = TRUE;
    Settings.DisconnectTimeoutMs = disconnect_timeout_ms;
    Settings.IsSet.DisconnectTimeoutMs = TRUE;
    Settings.HandshakeIdleTimeoutMs = handshake_idle_timeout_ms;
    Settings.IsSet.HandshakeIdleTimeoutMs = TRUE;

    QUIC_BUFFER Alpn = { (uint32_t)strlen(alpn_str), (uint8_t*)alpn_str };
    
    // Create configuration
    if (QUIC_FAILED(Status = MsQuic->ConfigurationOpen(Registration, &Alpn, 1, &Settings, sizeof(Settings), NULL, &Configuration))) {
        rb_raise(rb_eRuntimeError, "Server ConfigurationOpen failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Set up server credentials with certificate files
    QUIC_CREDENTIAL_CONFIG CredConfig = {0};
    QUIC_CERTIFICATE_FILE CertFile = {0};
    
    CertFile.CertificateFile = cert_path;
    CertFile.PrivateKeyFile = key_path;
    
    CredConfig.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
    CredConfig.CertificateFile = &CertFile;
    CredConfig.Flags = QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION;
    
    if (QUIC_FAILED(Status = MsQuic->ConfigurationLoadCredential(Configuration, &CredConfig))) {
        MsQuic->ConfigurationClose(Configuration);
        rb_raise(rb_eRuntimeError, "Server ConfigurationLoadCredential failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Return the configuration handle as a Ruby integer (pointer)
    return ULL2NUM((uintptr_t)Configuration);
}

// Create a QUIC connection with context
static VALUE
quicsilver_create_connection(VALUE self, VALUE client_obj)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized. Call Quicsilver.open_connection first.");
        return Qnil;
    }

    QUIC_STATUS Status;
    HQUIC Connection = NULL;

    // Allocate and initialize connection context
    ConnectionContext* ctx = (ConnectionContext*)malloc(sizeof(ConnectionContext));
    if (ctx == NULL) {
        rb_raise(rb_eRuntimeError, "Failed to allocate connection context");
        return Qnil;
    }

    ctx->connected = 0;
    ctx->failed = 0;
    ctx->error_status = QUIC_STATUS_SUCCESS;
    ctx->error_code = 0;
    ctx->client_obj = client_obj;  // Store Ruby client object (Qnil for server)

    // Protect from GC if it's a Ruby object
    if (!NIL_P(client_obj)) {
        rb_gc_register_address(&ctx->client_obj);
    }

    // Create connection with enhanced callback and context
    if (QUIC_FAILED(Status = MsQuic->ConnectionOpen(Registration, ConnectionCallback, ctx, &Connection))) {
        if (!NIL_P(client_obj)) {
            rb_gc_unregister_address(&ctx->client_obj);
        }
        free(ctx);
        rb_raise(rb_eRuntimeError, "ConnectionOpen failed, 0x%x!", Status);
        return Qnil;
    }

    // Return both the connection handle and context as an array
    VALUE result = rb_ary_new2(2);
    rb_ary_push(result, ULL2NUM((uintptr_t)Connection));
    rb_ary_push(result, ULL2NUM((uintptr_t)ctx));
    return result;
}

// Start a QUIC connection
static VALUE
quicsilver_start_connection(VALUE self, VALUE connection_handle, VALUE config_handle, VALUE hostname, VALUE port)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qfalse;
    }
    
    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle);
    HQUIC Configuration = (HQUIC)(uintptr_t)NUM2ULL(config_handle);
    const char* Target = StringValueCStr(hostname);
    uint16_t Port = (uint16_t)NUM2INT(port);
    
    QUIC_STATUS Status;
    if (QUIC_FAILED(Status = MsQuic->ConnectionStart(Connection, Configuration, QUIC_ADDRESS_FAMILY_UNSPEC, Target, Port))) {
        rb_raise(rb_eRuntimeError, "ConnectionStart failed, 0x%x!", Status);
        return Qfalse;
    }

    wake_event_loop();
    return Qtrue;
}

// Sleep without GVL so other Ruby threads can run.
struct sleep_args { int ms; };
static void* sleep_nogvl(void* arg) {
    struct sleep_args* a = (struct sleep_args*)arg;
    struct timespec ts = { .tv_sec = a->ms / 1000, .tv_nsec = (a->ms % 1000) * 1000000 };
    nanosleep(&ts, NULL);
    return NULL;
}

// Wait for connection to complete (connected or failed).
// Uses non-blocking poll + GVL-releasing sleep so other threads aren't blocked.
static VALUE
quicsilver_wait_for_connection(VALUE self, VALUE context_handle, VALUE timeout_ms)
{
    ConnectionContext* ctx = (ConnectionContext*)(uintptr_t)NUM2ULL(context_handle);
    int timeout = NUM2INT(timeout_ms);
    int elapsed = 0;
    const int sleep_interval = 5; // 5ms
    
    while (elapsed < timeout && !ctx->connected && !ctx->failed) {
        // Release GVL while sleeping — other threads can run.
        // MsQuic fires CONNECTION_CONNECTED on its own thread,
        // setting ctx->connected directly.
        struct sleep_args sa = { .ms = sleep_interval };
        rb_thread_call_without_gvl(sleep_nogvl, &sa, RUBY_UBF_IO, NULL);
        elapsed += sleep_interval;
    }
    
    if (ctx->connected) {
        return rb_hash_new();
    } else if (ctx->failed) {
        VALUE error_info = rb_hash_new();
        rb_hash_aset(error_info, rb_str_new_cstr("error"), Qtrue);
        rb_hash_aset(error_info, rb_str_new_cstr("status"), ULL2NUM(ctx->error_status));
        rb_hash_aset(error_info, rb_str_new_cstr("code"), ULL2NUM(ctx->error_code));
        
        return error_info;
    } else {
        VALUE timeout_info = rb_hash_new();
        rb_hash_aset(timeout_info, rb_str_new_cstr("timeout"), Qtrue);
        return timeout_info;
    }
}

// Check connection status
static VALUE
quicsilver_connection_status(VALUE self, VALUE context_handle)
{
    ConnectionContext* ctx = (ConnectionContext*)(uintptr_t)NUM2ULL(context_handle);
    
    VALUE status = rb_hash_new();
    rb_hash_aset(status, rb_str_new_cstr("connected"), ctx->connected ? Qtrue : Qfalse);
    rb_hash_aset(status, rb_str_new_cstr("failed"), ctx->failed ? Qtrue : Qfalse);
    
    if (ctx->failed) {
        rb_hash_aset(status, rb_str_new_cstr("error_status"), ULL2NUM(ctx->error_status));
        rb_hash_aset(status, rb_str_new_cstr("error_code"), ULL2NUM(ctx->error_code));
    }
    
    return status;
}

// Get QUIC connection statistics (QUIC_STATISTICS_V2)
static VALUE
quicsilver_connection_statistics(VALUE self, VALUE connection_handle_val)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }

    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle_val);
    if (Connection == NULL) return Qnil;

    QUIC_STATISTICS_V2 stats;
    uint32_t stats_size = sizeof(stats);
    memset(&stats, 0, stats_size);

    QUIC_STATUS status = MsQuic->GetParam(
        Connection,
        QUIC_PARAM_CONN_STATISTICS_V2,
        &stats_size,
        &stats);

    if (QUIC_FAILED(status)) {
        return Qnil;
    }

    VALUE result = rb_hash_new();

    // RTT (microseconds)
    rb_hash_aset(result, rb_str_new_cstr("rtt"), UINT2NUM(stats.Rtt));
    rb_hash_aset(result, rb_str_new_cstr("min_rtt"), UINT2NUM(stats.MinRtt));
    rb_hash_aset(result, rb_str_new_cstr("max_rtt"), UINT2NUM(stats.MaxRtt));

    // Handshake
    rb_hash_aset(result, rb_str_new_cstr("resumption_attempted"), stats.ResumptionAttempted ? Qtrue : Qfalse);
    rb_hash_aset(result, rb_str_new_cstr("resumption_succeeded"), stats.ResumptionSucceeded ? Qtrue : Qfalse);

    // Send
    rb_hash_aset(result, rb_str_new_cstr("send_path_mtu"), UINT2NUM(stats.SendPathMtu));
    rb_hash_aset(result, rb_str_new_cstr("send_total_packets"), ULL2NUM(stats.SendTotalPackets));
    rb_hash_aset(result, rb_str_new_cstr("send_retransmittable_packets"), ULL2NUM(stats.SendRetransmittablePackets));
    rb_hash_aset(result, rb_str_new_cstr("send_suspected_lost_packets"), ULL2NUM(stats.SendSuspectedLostPackets));
    rb_hash_aset(result, rb_str_new_cstr("send_spurious_lost_packets"), ULL2NUM(stats.SendSpuriousLostPackets));
    rb_hash_aset(result, rb_str_new_cstr("send_total_bytes"), ULL2NUM(stats.SendTotalBytes));
    rb_hash_aset(result, rb_str_new_cstr("send_total_stream_bytes"), ULL2NUM(stats.SendTotalStreamBytes));
    rb_hash_aset(result, rb_str_new_cstr("send_congestion_count"), UINT2NUM(stats.SendCongestionCount));
    rb_hash_aset(result, rb_str_new_cstr("send_persistent_congestion_count"), UINT2NUM(stats.SendPersistentCongestionCount));
    rb_hash_aset(result, rb_str_new_cstr("send_congestion_window"), UINT2NUM(stats.SendCongestionWindow));

    // Recv
    rb_hash_aset(result, rb_str_new_cstr("recv_total_packets"), ULL2NUM(stats.RecvTotalPackets));
    rb_hash_aset(result, rb_str_new_cstr("recv_reordered_packets"), ULL2NUM(stats.RecvReorderedPackets));
    rb_hash_aset(result, rb_str_new_cstr("recv_dropped_packets"), ULL2NUM(stats.RecvDroppedPackets));
    rb_hash_aset(result, rb_str_new_cstr("recv_duplicate_packets"), ULL2NUM(stats.RecvDuplicatePackets));
    rb_hash_aset(result, rb_str_new_cstr("recv_total_bytes"), ULL2NUM(stats.RecvTotalBytes));
    rb_hash_aset(result, rb_str_new_cstr("recv_total_stream_bytes"), ULL2NUM(stats.RecvTotalStreamBytes));
    rb_hash_aset(result, rb_str_new_cstr("recv_decryption_failures"), ULL2NUM(stats.RecvDecryptionFailures));
    rb_hash_aset(result, rb_str_new_cstr("recv_valid_ack_frames"), ULL2NUM(stats.RecvValidAckFrames));

    // Misc
    rb_hash_aset(result, rb_str_new_cstr("key_update_count"), UINT2NUM(stats.KeyUpdateCount));

    return result;
}

// Close a QUIC connection and free context
static VALUE
quicsilver_close_connection_handle(VALUE self, VALUE connection_data)
{
    if (MsQuic == NULL) {
        return Qnil;
    }

    // Extract connection handle and context from array
    VALUE connection_handle = rb_ary_entry(connection_data, 0);
    VALUE context_handle = rb_ary_entry(connection_data, 1);

    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle);
    (void)context_handle; // ctx freed by SHUTDOWN_COMPLETE, not here

    if (Connection != NULL) {
        MsQuic->ConnectionClose(Connection);
    }

    // Don't free ctx here — ConnectionClose is async and SHUTDOWN_COMPLETE
    // will fire on the next event loop poll, which still needs ctx.
    // SHUTDOWN_COMPLETE handles cleanup for both client and server.

    return Qnil;
}

// Close a server-side connection handle (context already freed in C callback)
static VALUE
quicsilver_close_server_connection(VALUE self, VALUE connection_handle)
{
    if (MsQuic == NULL) return Qnil;

    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle);
    if (Connection != NULL) {
        MsQuic->ConnectionClose(Connection);
    }
    return Qnil;
}

// Gracefully shutdown a QUIC connection (sends CONNECTION_CLOSE frame to peer)
// silent = true: immediate shutdown without notifying peer
// silent = false: graceful shutdown with CONNECTION_CLOSE frame
static VALUE
quicsilver_connection_shutdown(VALUE self, VALUE connection_handle, VALUE error_code, VALUE silent)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }

    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle);
    uint64_t ErrorCode = NUM2ULL(error_code);

    if (Connection != NULL) {
        QUIC_CONNECTION_SHUTDOWN_FLAGS flags = RTEST(silent)
            ? QUIC_CONNECTION_SHUTDOWN_FLAG_SILENT
            : QUIC_CONNECTION_SHUTDOWN_FLAG_NONE;

        MsQuic->ConnectionShutdown(Connection, flags, ErrorCode);
        wake_event_loop();
    }

    return Qtrue;
}

// Close a QUIC configuration
static VALUE
quicsilver_close_configuration(VALUE self, VALUE config_handle)
{
    if (MsQuic == NULL) {
        return Qnil;
    }
    
    HQUIC Configuration = (HQUIC)(uintptr_t)NUM2ULL(config_handle);
    MsQuic->ConfigurationClose(Configuration);
    return Qnil;
}

static VALUE
quicsilver_close(VALUE self)
{
    if (MsQuic != NULL) {
        if (Registration != NULL) {
            // Force-close all connections (abortive shutdown).
            // Without this, RegistrationClose blocks waiting for
            // graceful close of connections that tests didn't clean up.
            MsQuic->RegistrationShutdown(
                Registration,
                QUIC_CONNECTION_SHUTDOWN_FLAG_SILENT,
                0
            );
            MsQuic->RegistrationClose(Registration);
            Registration = NULL;
        }

        // Drain any remaining buffered events before closing
        quicsilver_drain_queue(self);

        MsQuicClose(MsQuic);
        MsQuic = NULL;
    }

    // Close notification pipe after everything is drained
    if (notify_pipe[0] != -1) { close(notify_pipe[0]); notify_pipe[0] = -1; }
    if (notify_pipe[1] != -1) { close(notify_pipe[1]); notify_pipe[1] = -1; }

    return Qnil;
}

// Create a QUIC listener
static VALUE
quicsilver_create_listener(VALUE self, VALUE config_handle)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }
    
    HQUIC Configuration = (HQUIC)(uintptr_t)NUM2ULL(config_handle);
    HQUIC Listener = NULL;
    QUIC_STATUS Status;
    
    // Create listener context
    ListenerContext* ctx = (ListenerContext*)malloc(sizeof(ListenerContext));
    if (ctx == NULL) {
        rb_raise(rb_eRuntimeError, "Failed to allocate listener context");
        return Qnil;
    }
    
    ctx->started = 0;
    ctx->stopped = 0;
    ctx->failed = 0;
    ctx->error_status = QUIC_STATUS_SUCCESS;
    ctx->Configuration = Configuration;
    
    // Create listener
    if (QUIC_FAILED(Status = MsQuic->ListenerOpen(Registration, ListenerCallback, ctx, &Listener))) {
        free(ctx);
        rb_raise(rb_eRuntimeError, "ListenerOpen failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Return listener handle and context
    VALUE result = rb_ary_new2(2);
    rb_ary_push(result, ULL2NUM((uintptr_t)Listener));
    rb_ary_push(result, ULL2NUM((uintptr_t)ctx));
    return result;
}

// Start listener on specific address and port
static VALUE
quicsilver_start_listener(VALUE self, VALUE listener_handle, VALUE address, VALUE port, VALUE alpn)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qfalse;
    }

    HQUIC Listener = (HQUIC)(uintptr_t)NUM2ULL(listener_handle);
    uint16_t Port = (uint16_t)NUM2INT(port);
    const char* alpn_str = StringValueCStr(alpn);

    // Setup address - properly initialize the entire structure
    QUIC_ADDR Address;
    memset(&Address, 0, sizeof(Address));

    // Parse address string to determine family
    const char* addr_str = StringValueCStr(address);
    if (strchr(addr_str, ':') != NULL) {
        // IPv6 address (contains ':')
        QuicAddrSetFamily(&Address, QUIC_ADDRESS_FAMILY_INET6);
    } else {
        // IPv4 address or unspecified - use UNSPEC for dual-stack
        QuicAddrSetFamily(&Address, QUIC_ADDRESS_FAMILY_UNSPEC);
    }
    QuicAddrSetPort(&Address, Port);

    QUIC_STATUS Status;

    QUIC_BUFFER AlpnBuffer = { (uint32_t)strlen(alpn_str), (uint8_t*)alpn_str };

    if (QUIC_FAILED(Status = MsQuic->ListenerStart(Listener, &AlpnBuffer, 1, &Address))) {
        rb_raise(rb_eRuntimeError, "ListenerStart failed, 0x%x!", Status);
        return Qfalse;
    }

    wake_event_loop();
    return Qtrue;
}

// Stop listener
static VALUE
quicsilver_stop_listener(VALUE self, VALUE listener_handle)
{
    if (MsQuic == NULL) {
        return Qfalse;
    }

    HQUIC Listener = (HQUIC)(uintptr_t)NUM2ULL(listener_handle);
    MsQuic->ListenerStop(Listener);
    wake_event_loop();
    return Qtrue;
}

// Close listener
static VALUE
quicsilver_close_listener(VALUE self, VALUE listener_data)
{
    if (MsQuic == NULL) {
        return Qnil;
    }
    
    VALUE listener_handle = rb_ary_entry(listener_data, 0);
    VALUE context_handle = rb_ary_entry(listener_data, 1);
    
    HQUIC Listener = (HQUIC)(uintptr_t)NUM2ULL(listener_handle);
    ListenerContext* ctx = (ListenerContext*)(uintptr_t)NUM2ULL(context_handle);
    
    MsQuic->ListenerClose(Listener);
    
    if (ctx != NULL) {
        free(ctx);
    }
    
    return Qnil;
}

// Open a QUIC stream
// Accepts connection_data array [connection_handle, context_handle]
// Works uniformly for both client and server
static VALUE
quicsilver_open_stream(VALUE self, VALUE connection_data, VALUE unidirectional)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }

    // Extract connection handle and context from array
    VALUE connection_handle = rb_ary_entry(connection_data, 0);
    VALUE context_handle = rb_ary_entry(connection_data, 1);

    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle);
    ConnectionContext* conn_ctx = (ConnectionContext*)(uintptr_t)NUM2ULL(context_handle);
    HQUIC Stream = NULL;

    StreamContext* ctx = (StreamContext*)malloc(sizeof(StreamContext));
    if (ctx == NULL) {
        rb_raise(rb_eRuntimeError, "Failed to allocate stream context");
        return Qnil;
    }

    ctx->connection = Connection;
    ctx->connection_ctx = conn_ctx;  // Store connection context pointer
    ctx->client_obj = conn_ctx ? conn_ctx->client_obj : Qnil;
    ctx->stream_id = UINT64_MAX;  // Sentinel: lazily resolved on first callback
    ctx->started = 1;
    ctx->shutdown = 0;
    ctx->early_data = 0;
    ctx->error_status = QUIC_STATUS_SUCCESS;

    // Use flag based on parameter
    QUIC_STREAM_OPEN_FLAGS flags = RTEST(unidirectional)
        ? QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL
        : QUIC_STREAM_OPEN_FLAG_NONE;

    // Create stream
    QUIC_STATUS Status = MsQuic->StreamOpen(Connection, flags, StreamCallback, ctx, &Stream);
    if (QUIC_FAILED(Status)) {
        free(ctx);
        rb_raise(rb_eRuntimeError, "StreamOpen failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Start the stream
    Status = MsQuic->StreamStart(Stream, QUIC_STREAM_START_FLAG_NONE);
    if (QUIC_FAILED(Status)) {
        // StreamClose fires SHUTDOWN_COMPLETE synchronously which frees ctx
        MsQuic->StreamClose(Stream);
        rb_raise(rb_eRuntimeError, "StreamStart failed, 0x%x!", Status);
        return Qnil;
    }

    wake_event_loop();
    return ULL2NUM((uintptr_t)Stream);
}

// Send data on a QUIC stream
static VALUE
quicsilver_send_stream(VALUE self, VALUE stream_handle, VALUE data, VALUE send_fin)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }

    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    // Use StringValuePtr and RSTRING_LEN for binary data with null bytes
    const char* data_str = RSTRING_PTR(data);
    uint32_t data_len = (uint32_t)RSTRING_LEN(data);
    
    void* SendBufferRaw = malloc(sizeof(QUIC_BUFFER) + data_len);
    if (SendBufferRaw == NULL) {
        rb_raise(rb_eRuntimeError, "SendBuffer allocation failed!");
        return Qnil;
    }

    QUIC_BUFFER* SendBuffer = (QUIC_BUFFER*)SendBufferRaw;
    SendBuffer->Buffer = (uint8_t*)SendBufferRaw + sizeof(QUIC_BUFFER);
    SendBuffer->Length = data_len;

    memcpy(SendBuffer->Buffer, data_str, data_len);

    // Use flag based on parameter (default to FIN for backwards compat)
    QUIC_SEND_FLAGS flags = (NIL_P(send_fin) || RTEST(send_fin))
        ? QUIC_SEND_FLAG_FIN
        : QUIC_SEND_FLAG_NONE;
    
    QUIC_STATUS Status = MsQuic->StreamSend(Stream, SendBuffer, 1, flags, SendBufferRaw);
    if (QUIC_FAILED(Status)) {
        free(SendBufferRaw);
        rb_raise(rb_eRuntimeError, "StreamSend failed, 0x%x!", Status);
        return Qfalse;
    }

    wake_event_loop();
    return Qtrue;
}

// Get the QUIC stream ID for an open stream.
// Must be called after data has been sent (MsQuic defers ID assignment
// with QUIC_STREAM_START_FLAG_NONE until data flows).
static VALUE
quicsilver_get_stream_id(VALUE self, VALUE stream_handle)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }
    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    uint64_t stream_id = 0;
    uint32_t stream_id_len = sizeof(stream_id);
    QUIC_STATUS Status = MsQuic->GetParam(Stream, QUIC_PARAM_STREAM_ID, &stream_id_len, &stream_id);
    if (QUIC_FAILED(Status)) {
        return Qnil;
    }
    return ULL2NUM(stream_id);
}

// Reset a QUIC stream (RESET_STREAM frame - abruptly terminates sending)
static VALUE
quicsilver_stream_reset(VALUE self, VALUE stream_handle, VALUE error_code)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }

    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    if (Stream == NULL) return Qnil;

    uint64_t ErrorCode = NUM2ULL(error_code);

    MsQuic->StreamShutdown(Stream, QUIC_STREAM_SHUTDOWN_FLAG_ABORT_SEND, ErrorCode);

    wake_event_loop();
    return Qtrue;
}

// Queue a stream priority change. Called from Ruby threads — just stores the
// priority. The actual SetParam happens on the MsQuic event thread in StreamCallback.
static VALUE
quicsilver_set_stream_priority(VALUE self, VALUE stream_handle, VALUE priority)
{
    if (MsQuic == NULL) return Qnil;

    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    if (Stream == NULL) return Qnil;

    if (PendingPriorityCount >= MAX_PENDING_PRIORITIES) return Qfalse;

    uint16_t Priority = (uint16_t)NUM2UINT(priority);
    PendingPriorities[PendingPriorityCount].stream = Stream;
    PendingPriorities[PendingPriorityCount].priority_plus_one = Priority + 1;
    PendingPriorityCount++;

    wake_event_loop();
    return Qtrue;
}

// Stop sending on a QUIC stream (STOP_SENDING frame - requests peer to stop)
static VALUE
quicsilver_stream_stop_sending(VALUE self, VALUE stream_handle, VALUE error_code)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }

    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    if (Stream == NULL) return Qnil;

    uint64_t ErrorCode = NUM2ULL(error_code);

    MsQuic->StreamShutdown(Stream, QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE, ErrorCode);

    wake_event_loop();
    return Qtrue;
}

static VALUE
quicsilver_wake(VALUE self)
{
    wake_event_loop();
    return Qnil;
}

// Non-blocking poll: drains the event buffer. Alias for drain_queue.
static VALUE
quicsilver_poll_nonblock(VALUE self)
{
    return quicsilver_drain_queue(self);
}

// Return the notification pipe read fd for Ruby to watch
static VALUE
quicsilver_notify_fd(VALUE self)
{
    if (notify_pipe[0] == -1) return Qnil;
    return INT2NUM(notify_pipe[0]);
}

// Drain buffered events, dispatch to Ruby. Returns event count.
static VALUE
quicsilver_drain_queue(VALUE self)
{
    pthread_mutex_lock(&EventBufferMutex);
    int count = EventBufferCount;
    BufferedEvent* copy = NULL;
    if (count > 0) {
        copy = (BufferedEvent*)malloc(count * sizeof(BufferedEvent));
        memcpy(copy, EventBuffer, count * sizeof(BufferedEvent));
        EventBufferCount = 0;
    }
    pthread_mutex_unlock(&EventBufferMutex);

    // Drain notify pipe
    if (notify_pipe[0] != -1) {
        char buf[64];
        while (read(notify_pipe[0], buf, sizeof(buf)) > 0) {}
    }

    for (int i = 0; i < count; i++) {
        BufferedEvent* ev = &copy[i];
        dispatch_to_ruby(ev->connection, ev->connection_ctx, ev->client_obj,
            EVENT_TYPE_NAMES[ev->event_type], ev->stream_id,
            ev->data, ev->data_len, ev->early_data);
        free(ev->data);

        // Deferred cleanup for CONNECTION_CLOSED — ctx was kept alive
        // so the event buffer could reference client_obj.
        if (ev->event_type == EVT_CONN_CLOSED && ev->connection_ctx) {
            ConnectionContext* ctx = (ConnectionContext*)ev->connection_ctx;
            if (!NIL_P(ctx->client_obj)) {
                rb_gc_unregister_address(&ctx->client_obj);
            }
            free(ctx);
        }
    }
    free(copy);

    return INT2NUM(count);
}

// Initialize the extension
void
Init_quicsilver(void)
{
    mQuicsilver = rb_define_module("Quicsilver");

    // Initialize notification pipe
    if (pipe(notify_pipe) == 0) {
        int flags = fcntl(notify_pipe[0], F_GETFL, 0);
        fcntl(notify_pipe[0], F_SETFL, flags | O_NONBLOCK);
        flags = fcntl(notify_pipe[1], F_GETFL, 0);
        fcntl(notify_pipe[1], F_SETFL, flags | O_NONBLOCK);
    }

    // Core initialization
    rb_define_singleton_method(mQuicsilver, "open_connection", quicsilver_open, 0);
    rb_define_singleton_method(mQuicsilver, "close_connection", quicsilver_close, 0);
    
    // Configuration management
    rb_define_singleton_method(mQuicsilver, "create_configuration", quicsilver_create_configuration, 1);
    rb_define_singleton_method(mQuicsilver, "create_server_configuration", quicsilver_create_server_configuration, 1);
    rb_define_singleton_method(mQuicsilver, "close_configuration", quicsilver_close_configuration, 1);
    
    // Connection management
    rb_define_singleton_method(mQuicsilver, "create_connection", quicsilver_create_connection, 1);
    rb_define_singleton_method(mQuicsilver, "start_connection", quicsilver_start_connection, 4);
    rb_define_singleton_method(mQuicsilver, "wait_for_connection", quicsilver_wait_for_connection, 2);
    rb_define_singleton_method(mQuicsilver, "connection_status", quicsilver_connection_status, 1);
    rb_define_singleton_method(mQuicsilver, "connection_statistics", quicsilver_connection_statistics, 1);
    rb_define_singleton_method(mQuicsilver, "connection_shutdown", quicsilver_connection_shutdown, 3);
    rb_define_singleton_method(mQuicsilver, "close_connection_handle", quicsilver_close_connection_handle, 1);
    rb_define_singleton_method(mQuicsilver, "close_server_connection", quicsilver_close_server_connection, 1);
    
    // Listener management
    rb_define_singleton_method(mQuicsilver, "create_listener", quicsilver_create_listener, 1);
    rb_define_singleton_method(mQuicsilver, "start_listener", quicsilver_start_listener, 4);
    rb_define_singleton_method(mQuicsilver, "stop_listener", quicsilver_stop_listener, 1);
    rb_define_singleton_method(mQuicsilver, "close_listener", quicsilver_close_listener, 1);

    // Stream management
    rb_define_singleton_method(mQuicsilver, "open_stream", quicsilver_open_stream, 2);
    rb_define_singleton_method(mQuicsilver, "send_stream", quicsilver_send_stream, 3);
    rb_define_singleton_method(mQuicsilver, "stream_reset", quicsilver_stream_reset, 2);
    rb_define_singleton_method(mQuicsilver, "stream_stop_sending", quicsilver_stream_stop_sending, 2);
    rb_define_singleton_method(mQuicsilver, "set_stream_priority", quicsilver_set_stream_priority, 2);
    rb_define_singleton_method(mQuicsilver, "get_stream_id", quicsilver_get_stream_id, 1);

    // Event processing (custom execution — app drives MsQuic)
    rb_define_singleton_method(mQuicsilver, "poll", quicsilver_poll, 0);
    rb_define_singleton_method(mQuicsilver, "poll_nonblock", quicsilver_poll_nonblock, 0);
    rb_define_singleton_method(mQuicsilver, "wake", quicsilver_wake, 0);
    rb_define_singleton_method(mQuicsilver, "notify_fd", quicsilver_notify_fd, 0);
    rb_define_singleton_method(mQuicsilver, "drain_queue", quicsilver_drain_queue, 0);
}
