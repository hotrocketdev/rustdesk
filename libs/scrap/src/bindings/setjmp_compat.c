int setjmp(void *buf);

/*
 * The MinGW-built libvpx objects reference `_setjmp`, but the active CRT in
 * this toolchain exports `setjmp`. Provide a small compatibility shim so the
 * branded Windows GNU runtime can link without pulling in a second CRT.
 */
int _setjmp(void *buf, void *ctx) {
    (void)ctx;
    return setjmp(buf);
}
