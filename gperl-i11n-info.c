/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

/* Caller owns return value */
static GIFunctionInfo *
get_function_info (GIRepository *repository,
                   const gchar *basename,
                   const gchar *namespace,
                   const gchar *method)
{
	dwarn ("%s: %s, %s, %s\n", G_STRFUNC, basename, namespace, method);

	if (namespace) {
		GIFunctionInfo *function_info = NULL;
		GIBaseInfo *namespace_info = g_irepository_find_by_name (
			repository, basename, namespace);
		if (!namespace_info)
			ccroak ("Can't find information for namespace %s",
			       namespace);

		switch (g_base_info_get_type (namespace_info)) {
		    case GI_INFO_TYPE_OBJECT:
			function_info = g_object_info_find_method (
				(GIObjectInfo *) namespace_info,
				method);
			break;
		    case GI_INFO_TYPE_INTERFACE:
			function_info = g_interface_info_find_method (
				(GIInterfaceInfo *) namespace_info,
				method);
			break;
		    case GI_INFO_TYPE_BOXED:
		    case GI_INFO_TYPE_STRUCT:
			function_info = g_struct_info_find_method (
				(GIStructInfo *) namespace_info,
				method);
			break;
                    case GI_INFO_TYPE_UNION:
                        function_info = g_union_info_find_method (
                                (GIUnionInfo *) namespace_info,
                                method);
                        break;
		    default:
			ccroak ("Base info for namespace %s has incorrect type",
			       namespace);
		}

		if (!function_info)
			ccroak ("Can't find information for method "
			       "%s::%s", namespace, method);

		g_base_info_unref (namespace_info);

		return function_info;
	} else {
		GIBaseInfo *method_info = g_irepository_find_by_name (
			repository, basename, method);

		if (!method_info)
			ccroak ("Can't find information for method %s", method);

		switch (g_base_info_get_type (method_info)) {
		    case GI_INFO_TYPE_FUNCTION:
			return (GIFunctionInfo *) method_info;
		    default:
			ccroak ("Base info for method %s has incorrect type",
			       method);
		}
	}

	return NULL;
}

/* Caller owns return value */
static GIFieldInfo *
get_field_info (GIBaseInfo *info, const gchar *field_name)
{
	GIInfoType info_type;
	info_type = g_base_info_get_type (info);
	switch (info_type) {
	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		gint n_fields, i;
		n_fields = g_struct_info_get_n_fields ((GIStructInfo *) info);
		for (i = 0; i < n_fields; i++) {
			GIFieldInfo *field_info;
			field_info = g_struct_info_get_field ((GIStructInfo *) info, i);
			if (0 == strcmp (field_name, g_base_info_get_name (field_info))) {
				return field_info;
			}
			g_base_info_unref (field_info);
		}
		break;
	    }
	    case GI_INFO_TYPE_UNION:
	    {
		gint n_fields, i;
		n_fields = g_union_info_get_n_fields ((GIStructInfo *) info);
		for (i = 0; i < n_fields; i++) {
			GIFieldInfo *field_info;
			field_info = g_union_info_get_field ((GIStructInfo *) info, i);
			if (0 == strcmp (field_name, g_base_info_get_name (field_info))) {
				return field_info;
			}
			g_base_info_unref (field_info);
		}
		break;
	    }
	    default:
		break;
	}
	return NULL;
}
