#include <ruby.h>
#include "msquic.h"

static VALUE mQuicsilver;

// Initialize MSQUIC
static VALUE
quicsilver_open(VALUE self)
{
    // For now, return a dummy handle to avoid segfault
    // TODO: Properly initialize MSQUIC
    return ULL2NUM(12345);
}

// Close MSQUIC
static VALUE
quicsilver_close(VALUE self)
{
    // For now, just return nil
    // TODO: Properly close MSQUIC
    return Qnil;
}

// Initialize the extension
void
Init_quicsilver(void)
{
    mQuicsilver = rb_define_module("Quicsilver");
    
    rb_define_singleton_method(mQuicsilver, "open_connection", quicsilver_open, 0);
    rb_define_singleton_method(mQuicsilver, "close_connection", quicsilver_close, 0);
}