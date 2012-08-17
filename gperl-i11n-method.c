/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

#define PUSH_METHODS(prefix, av, info)                                  \
	gint i, n_methods = g_ ## prefix ## _info_get_n_methods (info); \
	for (i = 0; i < n_methods; i++) { \
		GIFunctionInfo *function_info; \
		const gchar *function_name; \
		function_info = g_ ## prefix ## _info_get_method (info, i); \
		function_name = g_base_info_get_name (function_info); \
		av_push (av, newSVpv (function_name, PL_na)); \
		g_base_info_unref (function_info); \
	}

static void
store_methods (HV *namespaced_functions, GIBaseInfo *info, GIInfoType info_type)
{
	const gchar *namespace;
	AV *av;

	namespace = g_base_info_get_name (info);
	av = newAV ();

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    {
		PUSH_METHODS (object, av, info);
		break;
	    }

	    case GI_INFO_TYPE_INTERFACE:
	    {
		PUSH_METHODS (interface, av, info);
		break;
	    }

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		PUSH_METHODS (struct, av, info);
		break;
	    }

	    case GI_INFO_TYPE_UNION:
	    {
		PUSH_METHODS (union, av, info);
                break;
	    }

	    default:
		ccroak ("store_methods: unsupported info type %d", info_type);
	}

	gperl_hv_take_sv (namespaced_functions, namespace, strlen (namespace),
	                  newRV_noinc ((SV *) av));
}

/* ------------------------------------------------------------------------- */

static void
store_vfuncs (HV *objects_with_vfuncs, GIObjectInfo *info)
{
	const gchar *object_name;
	AV *vfuncs_av;
	gint n_vfuncs, i;

	n_vfuncs = g_object_info_get_n_vfuncs (info);
	if (n_vfuncs <= 0)
		return;

	object_name = g_base_info_get_name (info);
	vfuncs_av = newAV ();

	for (i = 0; i < n_vfuncs; i++) {
		GIVFuncInfo *vfunc_info =
			g_object_info_get_vfunc (info, i);
		const gchar *vfunc_name =
			g_base_info_get_name (vfunc_info);
		gchar *vfunc_perl_name = g_ascii_strup (vfunc_name, -1);
		AV *vfunc_av = newAV ();
		av_push (vfunc_av, newSVpv (vfunc_name, PL_na));
		av_push (vfunc_av, newSVpv (vfunc_perl_name, PL_na));
		av_push (vfuncs_av, newRV_noinc ((SV *) vfunc_av));
		g_free (vfunc_perl_name);
		g_base_info_unref (vfunc_info);
	}

	gperl_hv_take_sv (objects_with_vfuncs, object_name, strlen (object_name),
	                  newRV_noinc ((SV *) vfuncs_av));
}
