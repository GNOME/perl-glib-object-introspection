/* Call Carp's croak() so that errors are reported at their location in the
 * user's program, not in Introspection.pm.  Adapted from
 * <http://www.perlmonks.org/?node_id=865159>. */
static void
call_carp_croak (const char *msg)
{
	dSP;

	ENTER;
	SAVETMPS;

	PUSHMARK (SP);
	XPUSHs (sv_2mortal (newSVpv(msg, PL_na)));
	PUTBACK;

	call_pv("Carp::croak", G_VOID | G_DISCARD);

	FREETMPS;
	LEAVE;
}
