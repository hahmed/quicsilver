#include <ruby.h>
#include "msquic.h"

static VALUE mQuicsilver;

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
    VALUE ruby_callback;
} ConnectionContext;

// Stream state tracking (minimal)
typedef struct {
    int opened;
    int closed;
    int failed;
    QUIC_STATUS error_status;
    // Data transfer support
    char* receive_buffer;
    size_t receive_buffer_size;
    size_t received_bytes;
    int send_complete;
    int receive_complete;
} StreamContext;

// Listener state tracking
typedef struct {
    int started;
    int stopped;
    int failed;
    QUIC_STATUS error_status;
    VALUE ruby_callback;
    HQUIC Configuration;
} ListenerContext;

// Stream callback (minimal)
static QUIC_STATUS QUIC_API
StreamCallback(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event)
{
    StreamContext* ctx = (StreamContext*)Context;
    if (ctx == NULL) return QUIC_STATUS_SUCCESS;
    
    switch (Event->Type) {
        case QUIC_STREAM_EVENT_START_COMPLETE:
            ctx->opened = 1;
            break;
        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
            ctx->closed = 1;
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
            ctx->failed = 1;
            ctx->error_status = Event->PEER_SEND_ABORTED.ErrorCode;
            break;
        case QUIC_STREAM_EVENT_SEND_COMPLETE:
            ctx->send_complete = 1;
            break;
        case QUIC_STREAM_EVENT_RECEIVE:
            // Handle received data
            if (Event->RECEIVE.BufferCount > 0 && Event->RECEIVE.Buffers != NULL) {
                for (uint32_t i = 0; i < Event->RECEIVE.BufferCount; i++) {
                    QUIC_BUFFER* buffer = &Event->RECEIVE.Buffers[i];
                    if (buffer->Length > 0) {
                        // Expand receive buffer if needed
                        size_t needed_size = ctx->received_bytes + buffer->Length;
                        if (needed_size > ctx->receive_buffer_size) {
                            size_t new_size = needed_size * 2; // Double the size
                            char* new_buffer = (char*)realloc(ctx->receive_buffer, new_size);
                            if (new_buffer != NULL) {
                                ctx->receive_buffer = new_buffer;
                                ctx->receive_buffer_size = new_size;
                            }
                        }
                        
                        // Copy data if we have space
                        if (ctx->received_bytes + buffer->Length <= ctx->receive_buffer_size) {
                            memcpy(ctx->receive_buffer + ctx->received_bytes, buffer->Buffer, buffer->Length);
                            ctx->received_bytes += buffer->Length;
                        }
                    }
                }
            }
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
            ctx->receive_complete = 1;
            break;
        default:
            break;
    }
    return QUIC_STATUS_SUCCESS;
}

// Enhanced connection callback that handles key events
static QUIC_STATUS QUIC_API
ConnectionCallback(HQUIC Connection, void* Context, QUIC_CONNECTION_EVENT* Event)
{
    ConnectionContext* ctx = (ConnectionContext*)Context;
    
    if (ctx == NULL) {
        return QUIC_STATUS_SUCCESS;
    }
    
    switch (Event->Type) {
        case QUIC_CONNECTION_EVENT_CONNECTED:
            ctx->connected = 1;
            ctx->failed = 0;
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
                conn_ctx->ruby_callback = Qnil;
                
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
    QUIC_BUFFER Alpn = { sizeof("quicsilver") - 1, (uint8_t*)"quicsilver" };
    
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
quicsilver_create_server_configuration(VALUE self, VALUE cert_file, VALUE key_file)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized. Call Quicsilver.open_connection first.");
        return Qnil;
    }
    
    QUIC_STATUS Status;
    HQUIC Configuration = NULL;
    
    // Basic settings
    QUIC_SETTINGS Settings = {0};
    Settings.IdleTimeoutMs = 10000; // 10 second idle timeout for server
    Settings.IsSet.IdleTimeoutMs = TRUE;
    Settings.ServerResumptionLevel = QUIC_SERVER_RESUME_AND_ZERORTT;
    Settings.IsSet.ServerResumptionLevel = TRUE;
    Settings.PeerBidiStreamCount = 10;
    Settings.IsSet.PeerBidiStreamCount = TRUE;
    Settings.PeerUnidiStreamCount = 10;
    Settings.IsSet.PeerUnidiStreamCount = TRUE;
    
    // Simple ALPN for now - Ruby can customize this later
    QUIC_BUFFER Alpn = { sizeof("quicsilver") - 1, (uint8_t*)"quicsilver" };
    
    // Create configuration
    if (QUIC_FAILED(Status = MsQuic->ConfigurationOpen(Registration, &Alpn, 1, &Settings, sizeof(Settings), NULL, &Configuration))) {
        rb_raise(rb_eRuntimeError, "Server ConfigurationOpen failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Set up server credentials with certificate files
    QUIC_CREDENTIAL_CONFIG CredConfig = {0};
    QUIC_CERTIFICATE_FILE CertFile = {0};
    
    // Convert Ruby strings to C strings
    const char* cert_path = StringValueCStr(cert_file);
    const char* key_path = StringValueCStr(key_file);
    
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
quicsilver_create_connection(VALUE self)
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
    ctx->ruby_callback = Qnil;
    
    // Create connection with enhanced callback and context
    if (QUIC_FAILED(Status = MsQuic->ConnectionOpen(Registration, ConnectionCallback, ctx, &Connection))) {
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

// Configure MSQUIC for more verbose logging
void enable_msquic_logging() {
    QUIC_STATUS status = MsQuicOpenVersion(2, (const void**)&MsQuic);
    if (QUIC_FAILED(status)) {
        fprintf(stderr, "DEBUG: Failed to open MSQUIC for logging\n");
        return;
    }
    fprintf(stderr, "DEBUG: MSQUIC logging enabled\n");
    // Set logging level to verbose
    MsQuic->SetParam(NULL, QUIC_PARAM_GLOBAL_LOG_LEVEL, sizeof(QUIC_LOG_LEVEL), &QUIC_LOG_LEVEL_VERBOSE);
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
    
    enable_msquic_logging();
    
    fprintf(stderr, "DEBUG: start_connection succeeded\n");
    fprintf(stderr, "DEBUG: Waiting for handshake...\n");
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
        fprintf(stderr, "DEBUG: Handshake succeeded\n");
        return rb_hash_new();
    } else if (ctx->failed) {
        VALUE error_info = rb_hash_new();
        rb_hash_aset(error_info, rb_str_new_cstr("error"), Qtrue);
        rb_hash_aset(error_info, rb_str_new_cstr("status"), ULL2NUM(ctx->error_status));
        rb_hash_aset(error_info, rb_str_new_cstr("code"), ULL2NUM(ctx->error_code));
        fprintf(stderr, "DEBUG: Handshake failed: %s\n", rb_str_new_cstr(rb_inspect(error_info)));
        return error_info;
    } else {
        VALUE timeout_info = rb_hash_new();
        rb_hash_aset(timeout_info, rb_str_new_cstr("timeout"), Qtrue);
        fprintf(stderr, "DEBUG: Handshake timed out\n");
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
    
    MsQuic->ConnectionClose(Connection);
    
    if (ctx != NULL) {
        free(ctx);
    }
    
    return Qnil;
}

// Create a QUIC stream
static VALUE
quicsilver_create_stream(VALUE self, VALUE connection_handle, VALUE bidirectional)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qnil;
    }
    
    HQUIC Connection = (HQUIC)(uintptr_t)NUM2ULL(connection_handle);
    HQUIC Stream = NULL;
    QUIC_STATUS Status;
    
    // Create stream context
    StreamContext* ctx = (StreamContext*)malloc(sizeof(StreamContext));
    if (ctx == NULL) {
        rb_raise(rb_eRuntimeError, "Failed to allocate stream context");
        return Qnil;
    }
    
    ctx->opened = 0;
    ctx->closed = 0;
    ctx->failed = 0;
    ctx->error_status = QUIC_STATUS_SUCCESS;
    ctx->receive_buffer = NULL;
    ctx->receive_buffer_size = 0;
    ctx->received_bytes = 0;
    ctx->send_complete = 0;
    ctx->receive_complete = 0;
    
    // Determine stream flags
    QUIC_STREAM_OPEN_FLAGS flags = QUIC_STREAM_OPEN_FLAG_NONE;
    if (!RTEST(bidirectional)) {
        flags |= QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL;
    }
    
    // Create and start stream
    if (QUIC_FAILED(Status = MsQuic->StreamOpen(Connection, flags, StreamCallback, ctx, &Stream))) {
        free(ctx);
        rb_raise(rb_eRuntimeError, "StreamOpen failed, 0x%x!", Status);
        return Qnil;
    }
    
    if (QUIC_FAILED(Status = MsQuic->StreamStart(Stream, QUIC_STREAM_START_FLAG_NONE))) {
        MsQuic->StreamClose(Stream);
        free(ctx);
        rb_raise(rb_eRuntimeError, "StreamStart failed, 0x%x!", Status);
        return Qnil;
    }
    
    // Return stream handle and context
    VALUE result = rb_ary_new2(2);
    rb_ary_push(result, ULL2NUM((uintptr_t)Stream));
    rb_ary_push(result, ULL2NUM((uintptr_t)ctx));
    return result;
}

// Check stream status
static VALUE
quicsilver_stream_status(VALUE self, VALUE context_handle)
{
    StreamContext* ctx = (StreamContext*)(uintptr_t)NUM2ULL(context_handle);
    
    VALUE status = rb_hash_new();
    rb_hash_aset(status, rb_str_new_cstr("opened"), ctx->opened ? Qtrue : Qfalse);
    rb_hash_aset(status, rb_str_new_cstr("closed"), ctx->closed ? Qtrue : Qfalse);
    rb_hash_aset(status, rb_str_new_cstr("failed"), ctx->failed ? Qtrue : Qfalse);
    
    return status;
}

// Send data on stream
static VALUE
quicsilver_stream_send(VALUE self, VALUE stream_handle, VALUE data)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qfalse;
    }
    
    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    
    // Convert Ruby string to C string
    Check_Type(data, T_STRING);
    char* buffer = RSTRING_PTR(data);
    size_t length = RSTRING_LEN(data);
    
    if (length == 0) {
        return Qtrue; // Nothing to send
    }
    
    // Allocate buffer for the data (MSQUIC will free it)
    QUIC_BUFFER* quic_buffer = (QUIC_BUFFER*)malloc(sizeof(QUIC_BUFFER));
    if (quic_buffer == NULL) {
        rb_raise(rb_eRuntimeError, "Failed to allocate send buffer");
        return Qfalse;
    }
    
    // Copy data to new buffer
    char* send_buffer = (char*)malloc(length);
    if (send_buffer == NULL) {
        free(quic_buffer);
        rb_raise(rb_eRuntimeError, "Failed to allocate send data buffer");
        return Qfalse;
    }
    memcpy(send_buffer, buffer, length);
    
    quic_buffer->Buffer = (uint8_t*)send_buffer;
    quic_buffer->Length = (uint32_t)length;
    
    // Send the data
    QUIC_STATUS Status = MsQuic->StreamSend(Stream, quic_buffer, 1, QUIC_SEND_FLAG_NONE, quic_buffer);
    if (QUIC_FAILED(Status)) {
        free(send_buffer);
        free(quic_buffer);
        rb_raise(rb_eRuntimeError, "StreamSend failed, 0x%x!", Status);
        return Qfalse;
    }
    
    return Qtrue;
}

// Receive data from stream
static VALUE
quicsilver_stream_receive(VALUE self, VALUE context_handle)
{
    StreamContext* ctx = (StreamContext*)(uintptr_t)NUM2ULL(context_handle);
    
    if (ctx->received_bytes == 0) {
        return rb_str_new("", 0); // Return empty string if no data
    }
    
    // Create Ruby string from received data
    VALUE result = rb_str_new(ctx->receive_buffer, ctx->received_bytes);
    
    // Clear the buffer for next receive
    ctx->received_bytes = 0;
    
    return result;
}

// Check if stream has received data
static VALUE
quicsilver_stream_has_data(VALUE self, VALUE context_handle)
{
    StreamContext* ctx = (StreamContext*)(uintptr_t)NUM2ULL(context_handle);
    return ctx->received_bytes > 0 ? Qtrue : Qfalse;
}

// Shutdown stream sending
static VALUE
quicsilver_stream_shutdown_send(VALUE self, VALUE stream_handle)
{
    if (MsQuic == NULL) {
        rb_raise(rb_eRuntimeError, "MSQUIC not initialized.");
        return Qfalse;
    }
    
    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    
    QUIC_STATUS Status = MsQuic->StreamShutdown(Stream, QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0);
    if (QUIC_FAILED(Status)) {
        rb_raise(rb_eRuntimeError, "StreamShutdown failed, 0x%x!", Status);
        return Qfalse;
    }
    
    return Qtrue;
}

// Close stream
static VALUE
quicsilver_close_stream(VALUE self, VALUE stream_data)
{
    if (MsQuic == NULL) {
        return Qnil;
    }
    
    VALUE stream_handle = rb_ary_entry(stream_data, 0);
    VALUE context_handle = rb_ary_entry(stream_data, 1);
    
    HQUIC Stream = (HQUIC)(uintptr_t)NUM2ULL(stream_handle);
    StreamContext* ctx = (StreamContext*)(uintptr_t)NUM2ULL(context_handle);
    
    MsQuic->StreamClose(Stream);
    if (ctx != NULL) {
        if (ctx->receive_buffer != NULL) {
            free(ctx->receive_buffer);
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
    ctx->ruby_callback = Qnil;
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
    const char* addr_str = StringValueCStr(address);
    uint16_t Port = (uint16_t)NUM2INT(port);
    
    // Setup address - properly initialize the entire structure
    QUIC_ADDR Address;
    memset(&Address, 0, sizeof(Address));
    
    // Set up for localhost/any address
    QuicAddrSetFamily(&Address, QUIC_ADDRESS_FAMILY_INET);
    QuicAddrSetPort(&Address, Port);
    
    // For localhost, we can just use the default (any address)
    // The QuicAddrSetFamily and QuicAddrSetPort should be sufficient
    
    QUIC_STATUS Status;
    
    // Create QUIC_BUFFER for the address
    QUIC_BUFFER AlpnBuffer = { sizeof("quicsilver") - 1, (uint8_t*)"quicsilver" };
    
    if (QUIC_FAILED(Status = MsQuic->ListenerStart(Listener, &AlpnBuffer, 1, &Address))) {
        rb_raise(rb_eRuntimeError, "ListenerStart failed, 0x%x!", Status);
        return Qfalse;
    }
    
    fprintf(stderr, "DEBUG: start_listener succeeded\n");
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
    rb_define_singleton_method(mQuicsilver, "create_server_configuration", quicsilver_create_server_configuration, 2);
    rb_define_singleton_method(mQuicsilver, "close_configuration", quicsilver_close_configuration, 1);
    
    // Connection management  
    rb_define_singleton_method(mQuicsilver, "create_connection", quicsilver_create_connection, 0);
    rb_define_singleton_method(mQuicsilver, "start_connection", quicsilver_start_connection, 4);
    rb_define_singleton_method(mQuicsilver, "wait_for_connection", quicsilver_wait_for_connection, 2);
    rb_define_singleton_method(mQuicsilver, "connection_status", quicsilver_connection_status, 1);
    rb_define_singleton_method(mQuicsilver, "close_connection_handle", quicsilver_close_connection_handle, 1);
    rb_define_singleton_method(mQuicsilver, "create_stream", quicsilver_create_stream, 2);
    rb_define_singleton_method(mQuicsilver, "stream_status", quicsilver_stream_status, 1);
    rb_define_singleton_method(mQuicsilver, "close_stream", quicsilver_close_stream, 1);
    rb_define_singleton_method(mQuicsilver, "stream_send", quicsilver_stream_send, 2);
    rb_define_singleton_method(mQuicsilver, "stream_receive", quicsilver_stream_receive, 1);
    rb_define_singleton_method(mQuicsilver, "stream_has_data", quicsilver_stream_has_data, 1);
    rb_define_singleton_method(mQuicsilver, "stream_shutdown_send", quicsilver_stream_shutdown_send, 1);
    rb_define_singleton_method(mQuicsilver, "create_listener", quicsilver_create_listener, 1);
    rb_define_singleton_method(mQuicsilver, "start_listener", quicsilver_start_listener, 3);
    rb_define_singleton_method(mQuicsilver, "stop_listener", quicsilver_stop_listener, 1);
    rb_define_singleton_method(mQuicsilver, "close_listener", quicsilver_close_listener, 1);
}