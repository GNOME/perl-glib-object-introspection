/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static void
store_methods (HV *namespaced_functions, GIBaseInfo *info, GIInfoType info_type)
{
	const gchar *namespace;
	AV *av;
	gint i;

	namespace = g_base_info_get_name (info);
	av = newAV ();

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    {
		gint n_methods = g_object_info_get_n_methods (
		                   (GIObjectInfo *) info);
		for (i = 0; i < n_methods; i++) {
			GIFunctionInfo *function_info =
				g_object_info_get_method (
					(GIObjectInfo *) info, i);
			const gchar *function_name =
				g_base_info_get_name (
					(GIBaseInfo *) function_info);
			av_push (av, newSVpv (function_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) function_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_INTERFACE:
	    {
		gint n_methods = g_interface_info_get_n_methods (
		                   (GIInterfaceInfo *) info);
		for (i = 0; i < n_methods; i++) {
			GIFunctionInfo *function_info =
				g_interface_info_get_method (
					(GIInterfaceInfo *) info, i);
			const gchar *function_name =
				g_base_info_get_name (
					(GIBaseInfo *) function_info);
			av_push (av, newSVpv (function_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) function_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		gint n_methods = g_struct_info_get_n_methods (
		                   (GIStructInfo *) info);
		for (i = 0; i < n_methods; i++) {
			GIFunctionInfo *function_info =
				g_struct_info_get_method (
					(GIStructInfo *) info, i);
			const gchar *function_name =
				g_base_info_get_name (
					(GIBaseInfo *) function_info);
			av_push (av, newSVpv (function_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) function_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_UNION:
	    {
                gint n_methods = g_union_info_get_n_methods ((GIUnionInfo *) info);
                for (i = 0; i < n_methods; i++) {
                        GIFunctionInfo *function_info;
                        const gchar *function_name;

                        function_info = g_union_info_get_method ((GIUnionInfo *) info, i);
                        function_name = g_base_info_get_name ((GIBaseInfo *) function_info);

                        av_push (av, newSVpv (function_name, PL_na));
                        g_base_info_unref ((GIBaseInfo *) function_info);
                }
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
