static GPerlI11nCallbackInfo *
create_callback_closure (GITypeInfo *cb_type, SV *code)
{
	GPerlI11nCallbackInfo *info;

	info = g_new0 (GPerlI11nCallbackInfo, 1);
	info->interface =
		(GICallableInfo *) g_type_info_get_interface (cb_type);
	info->cif = g_new0 (ffi_cif, 1);
	info->closure =
		g_callable_info_prepare_closure (info->interface, info->cif,
		                                 invoke_callback, info);
	/* FIXME: This should most likely use SvREFCNT_inc instead of
	 * newSVsv. */
	info->code = newSVsv (code);
	info->sub_name = NULL;

#ifdef PERL_IMPLICIT_CONTEXT
	info->priv = aTHX;
#endif

	return info;
}

static void
attach_callback_data (GPerlI11nCallbackInfo *info, SV *data)
{
	info->data = newSVsv (data);
}

/* assumes ownership of sub_name and package_name */
static GPerlI11nCallbackInfo *
create_callback_closure_for_named_sub (GITypeInfo *cb_type, gchar *sub_name)
{
	GPerlI11nCallbackInfo *info;

	info = g_new0 (GPerlI11nCallbackInfo, 1);
	info->interface =
		(GICallableInfo *) g_type_info_get_interface (cb_type);
	info->cif = g_new0 (ffi_cif, 1);
	info->closure =
		g_callable_info_prepare_closure (info->interface, info->cif,
		                                 invoke_callback, info);
	info->sub_name = sub_name;
	info->code = NULL;
	info->data = NULL;

#ifdef PERL_IMPLICIT_CONTEXT
	info->priv = aTHX;
#endif

	return info;
}

static void
release_callback (gpointer data)
{
	GPerlI11nCallbackInfo *info = data;
	dwarn ("releasing callback info %p\n", info);

	if (info->cif)
		g_free (info->cif);

	if (info->closure)
		g_callable_info_free_closure (info->interface, info->closure);

	if (info->interface)
		g_base_info_unref ((GIBaseInfo*) info->interface);

	if (info->code)
		SvREFCNT_dec (info->code);
	if (info->data)
		SvREFCNT_dec (info->data);
	if (info->sub_name)
		g_free (info->sub_name);

	g_free (info);
}
