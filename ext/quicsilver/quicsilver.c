#include <ruby.h>
#include "msquic.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static VALUE mQuicsilver;

// Event queue for callbacks
typedef struct CallbackEvent {
    HQUIC connection;
    void* connection_ctx;  // ConnectionContext pointer for building connection_data
    VALUE client_obj;      // Ruby client object (for routing callbacks)
    char* event_type;
    uint64_t stream_id;
    char* data;
    size_t data_len;
    struct CallbackEvent* next;
} CallbackEvent;

static CallbackEvent* event_queue_head = NULL;
static CallbackEvent* event_queue_tail = NULL;
static pthread_mutex_t queue_mutex = PTHREAD_MUTEX_INITIALIZER;

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
    int started;
    int shutdown;
    QUIC_STATUS error_status;
} StreamContext;

// Enqueue a callback event (thread-safe)
// NOTE: Called from QUIC callback threads without GVL - cannot use Ruby API here
static void
enqueue_callback_event(HQUIC connection, void* connection_ctx, VALUE client_obj, const char* event_type, uint64_t stream_id, const char* data, size_t data_len)
{
    CallbackEvent* event = (CallbackEvent*)malloc(sizeof(CallbackEvent));
    if (event == NULL) return;

    event->connection = connection;
    event->connection_ctx = connection_ctx;  // Store context pointer
    event->client_obj = client_obj;          // Can be Qnil for server events
    event->event_type = strdup(event_type);
    event->stream_id = stream_id;
    event->data = (char*)malloc(data_len);
    if (event->data != NULL) {
        memcpy(event->data, data, data_len);
    }
    event->data_len = data_len;
    event->next = NULL;

    pthread_mutex_lock(&queue_mutex);
    if (event_queue_tail == NULL) {
        event_queue_head = event_queue_tail = event;
    } else {
        event_queue_tail->next = event;
        event_queue_tail = event;
    }
    pthread_mutex_unlock(&queue_mutex);
}

// Free a single event
static void
free_event(CallbackEvent* event)
{
    if (event == NULL) return;
    free(event->event_type);
    free(event->data);
    free(event);
}

// Process all pending callback events (called from Ruby)
static VALUE
quicsilver_process_events(VALUE self)
{
    CallbackEvent* event;
    VALUE server_class = Qnil;
    int processed = 0;

    // Get Server class for server events (client_obj == Qnil)
    server_class = rb_const_get_at(mQuicsilver, rb_intern("Server"));
    if (rb_class_real(CLASS_OF(server_class)) != rb_cClass) {
        server_class = Qnil;
    }

    // Process events in a loop, but limit iterations to avoid GVL starvation
    int max_iterations = 100;
    int iteration = 0;

    while (iteration++ < max_iterations) {
        pthread_mutex_lock(&queue_mutex);
        event = event_queue_head;
        if (event != NULL) {
            event_queue_head = event->next;
            if (event_queue_head == NULL) {
                event_queue_tail = NULL;
            }
        }
        pthread_mutex_unlock(&queue_mutex);

        if (event == NULL) break;

        // Route based on client_obj:
        // - If Qnil: server event, route to Server.handle_stream with connection_data
        // - If not Qnil: client event, route to client_obj.handle_stream_event
        int handled = 0;

        if (NIL_P(event->client_obj)) {
            // Server event - build connection_data array [connection_handle, context_ptr]
            if (!NIL_P(server_class)) {
                VALUE connection_data = rb_ary_new2(2);
                rb_ary_push(connection_data, ULL2NUM((uintptr_t)event->connection));
                rb_ary_push(connection_data, ULL2NUM((uintptr_t)event->connection_ctx));

                rb_funcall(server_class, rb_intern("handle_stream"), 4,
                    connection_data,
                    ULL2NUM(event->stream_id),
                    rb_str_new_cstr(event->event_type),
                    rb_str_new(event->data, event->data_len));
                handled = 1;
            }
        } else {
            // Client event - validate object is a real Ruby object before calling
            // This catches use-after-free when connection was closed but events still queued
            if (RB_TYPE_P(event->client_obj, T_OBJECT)) {
                rb_funcall(event->client_obj, rb_intern("handle_stream_event"), 3,
                    ULL2NUM(event->stream_id),
                    rb_str_new_cstr(event->event_type),
                    rb_str_new(event->data, event->data_len));
                handled = 1;
            }
        }

        if (handled) {
            processed++;
        }

        free_event(event);
    }

    return INT2NUM(processed);
}

QUIC_STATUS
StreamCallback(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event)
{
    StreamContext* ctx = (StreamContext*)Context;

    if (ctx == NULL) {
        return QUIC_STATUS_SUCCESS;
    }

    switch (Event->Type) {
        case QUIC_STREAM_EVENT_RECEIVE:
            // Client sent data - enqueue for Ruby processing
            if (Event->RECEIVE.BufferCount > 0) {
                const QUIC_BUFFER* buffer = &Event->RECEIVE.Buffers[0];
                const char* event_type = (Event->RECEIVE.Flags & QUIC_RECEIVE_FLAG_FIN) ? "RECEIVE_FIN" : "RECEIVE";

                // Get the QUIC protocol stream ID (0, 4, 8, 12...)
                uint64_t stream_id = 0;
                uint32_t stream_id_len = sizeof(stream_id);
                MsQuic->GetParam(Stream, QUIC_PARAM_STREAM_ID, &stream_id_len, &stream_id);

                // Pack stream handle pointer along with data for RECEIVE_FIN
                if (Event->RECEIVE.Flags & QUIC_RECEIVE_FLAG_FIN) {
                    // Create combined buffer: [stream_handle(8 bytes)][data]
                    size_t total_len = sizeof(HQUIC) + buffer->Length;
                    char* combined = (char*)malloc(total_len);
                    if (combined != NULL) {
                        memcpy(combined, &Stream, sizeof(HQUIC));
                        memcpy(combined + sizeof(HQUIC), buffer->Buffer, buffer->Length);
                        enqueue_callback_event(ctx->connection, ctx->connection_ctx, ctx->client_obj, event_type, stream_id, combined, total_len);
                        free(combined);
                    }
                } else {
                    enqueue_callback_event(ctx->connection, ctx->connection_ctx, ctx->client_obj, event_type, stream_id, (const char*)buffer->Buffer, buffer->Length);
                }
            }
            break;
        case QUIC_STREAM_EVENT_SEND_COMPLETE:
            break;
        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
            ctx->shutdown = 1;
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
            break;
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
            enqueue_callback_event(Connection, ctx, ctx->client_obj, "CONNECTION_ESTABLISHED", 0, (const char*)&Connection, sizeof(HQUIC));
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
            // Notify Ruby to clean up connection resources
            enqueue_callback_event(Connection, ctx, ctx->client_obj, "CONNECTION_CLOSED", 0, (const char*)&Connection, sizeof(HQUIC));
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
                stream_ctx->error_status = QUIC_STATUS_SUCCESS;

                // Set the stream callback handler to handle data events
                MsQuic->SetCallbackHandler(Stream, (void*)StreamCallback, stream_ctx);
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
    
    // Create a registration for the app's connections
    if (QUIC_FAILED(Status = MsQuic->RegistrationOpen(&RegConfig, &Registration))) {
        rb_raise(rb_eRuntimeError, "RegistrationOpen failed, 0x%x!", Status);
        MsQuicClose(MsQuic);
        MsQuic = NULL;
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
        rb_raise(rb_eRuntimeError, "ConfigurationLoadCredential failed, 0x%x!", Status);
        MsQuic->ConfigurationClose(Configuration);
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
    VALUE idle_timeout_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("idle_timeout")));
    VALUE server_resumption_level_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("server_resumption_level")));
    VALUE peer_bidi_stream_count_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("peer_bidi_stream_count")));
    VALUE peer_unidi_stream_count_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("peer_unidi_stream_count")));
    VALUE alpn_val = rb_hash_aref(config_hash, ID2SYM(rb_intern("alpn")));
    
    QUIC_STATUS Status;
    HQUIC Configuration = NULL;

    const char* cert_path = StringValueCStr(cert_file_val);
    const char* key_path = StringValueCStr(key_file_val);
    uint32_t idle_timeout_ms = NUM2INT(idle_timeout_val);
    uint32_t server_resumption_level = NUM2INT(server_resumption_level_val);
    uint32_t peer_bidi_stream_count = NUM2INT(peer_bidi_stream_count_val);
    uint32_t peer_unidi_stream_count = NUM2INT(peer_unidi_stream_count_val);
    const char* alpn_str = StringValueCStr(alpn_val);

    QUIC_SETTINGS Settings = {0};
    Settings.IdleTimeoutMs = idle_timeout_ms; 
    Settings.IsSet.IdleTimeoutMs = TRUE;
    Settings.ServerResumptionLevel = server_resumption_level;
    Settings.IsSet.ServerResumptionLevel = TRUE;
    Settings.PeerBidiStreamCount = peer_bidi_stream_count;
    Settings.IsSet.PeerBidiStreamCount = TRUE;
    Settings.PeerUnidiStreamCount = peer_unidi_stream_count;
    Settings.IsSet.PeerUnidiStreamCount = TRUE;

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
        rb_raise(rb_eRuntimeError, "Server ConfigurationLoadCredential failed, 0x%x!", Status);
        MsQuic->ConfigurationClose(Configuration);
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
    
    return Qtrue;
}

// Wait for connection to complete (connected or failed)
static VALUE
quicsilver_wait_for_connection(VALUE self, VALUE context_handle, VALUE timeout_ms)
{
    ConnectionContext* ctx = (ConnectionContext*)(uintptr_t)NUM2ULL(context_handle);
    int timeout = NUM2INT(timeout_ms);
    int elapsed = 0;
    const int sleep_interval = 10; // 10ms
    
    while (elapsed < timeout && !ctx->connected && !ctx->failed) {
        usleep(sleep_interval * 1000); // Convert to microseconds
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
    ConnectionContext* ctx = (ConnectionContext*)(uintptr_t)NUM2ULL(context_handle);
    
    // Only close if connection is valid
    if (Connection != NULL) {
        MsQuic->ConnectionClose(Connection);
    }

    // Free context if valid
    if (ctx != NULL) {
        // Unregister from GC if client object was set
        if (!NIL_P(ctx->client_obj)) {
            rb_gc_unregister_address(&ctx->client_obj);
        }
        free(ctx);
    }
    
    return Qnil;
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

// Close MSQUIC
static VALUE
quicsilver_close(VALUE self)
{
    if (MsQuic != NULL) {
        if (Registration != NULL) {
            // This will block until all outstanding child objects have been closed
            MsQuic->RegistrationClose(Registration);
            Registration = NULL;
        }
        MsQuicClose(MsQuic);
        MsQuic = NULL;
    }
    
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
quicsilver_start_listener(VALUE self, VALUE listener_handle, VALUE address, VALUE port)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qfalse;
    }
    
    HQUIC Listener = (HQUIC)(uintptr_t)NUM2ULL(listener_handle);
    uint16_t Port = (uint16_t)NUM2INT(port);
    
    // Setup address - properly initialize the entire structure
    QUIC_ADDR Address;
    memset(&Address, 0, sizeof(Address));
    
    // Set up for localhost/any address
    QuicAddrSetFamily(&Address, QUIC_ADDRESS_FAMILY_INET);
    QuicAddrSetPort(&Address, Port);
    
    QUIC_STATUS Status;
    
    // Create QUIC_BUFFER for the address
    QUIC_BUFFER AlpnBuffer = { sizeof("h3") - 1, (uint8_t*)"h3" };
    
    if (QUIC_FAILED(Status = MsQuic->ListenerStart(Listener, &AlpnBuffer, 1, &Address))) {
        rb_raise(rb_eRuntimeError, "ListenerStart failed, 0x%x!", Status);
        return Qfalse;
    }
    
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
    ctx->started = 1;
    ctx->shutdown = 0;
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
        free(ctx);
        MsQuic->StreamClose(Stream);
        rb_raise(rb_eRuntimeError, "StreamStart failed, 0x%x!", Status);
        return Qnil;
    }
    
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
    
    return Qtrue;
}  

// Initialize the extension
void
Init_quicsilver(void)
{
    mQuicsilver = rb_define_module("Quicsilver");

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
    rb_define_singleton_method(mQuicsilver, "close_connection_handle", quicsilver_close_connection_handle, 1);
    
    // Listener management
    rb_define_singleton_method(mQuicsilver, "create_listener", quicsilver_create_listener, 1);
    rb_define_singleton_method(mQuicsilver, "start_listener", quicsilver_start_listener, 3);
    rb_define_singleton_method(mQuicsilver, "stop_listener", quicsilver_stop_listener, 1);
    rb_define_singleton_method(mQuicsilver, "close_listener", quicsilver_close_listener, 1);

    // Stream management
    rb_define_singleton_method(mQuicsilver, "open_stream", quicsilver_open_stream, 2);
    rb_define_singleton_method(mQuicsilver, "send_stream", quicsilver_send_stream, 3);

    // Event processing
    rb_define_singleton_method(mQuicsilver, "process_events", quicsilver_process_events, 0);
}
