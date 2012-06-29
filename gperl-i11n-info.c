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

static GType
get_gtype (GIRegisteredTypeInfo *info)
{
	GType gtype = g_registered_type_info_get_g_type (info);
	if (gtype == G_TYPE_NONE) {
		/* Fall back to the registered type name, and if that doesn't
		 * work either, construct the full name and try that. */
		const gchar *type_name = g_registered_type_info_get_type_name (info);
		if (type_name) {
			gtype = g_type_from_name (type_name);
			return gtype ? gtype : G_TYPE_NONE;
		} else {
			gchar *full_name;
			const gchar *namespace = g_base_info_get_namespace (info);
			const gchar *name = g_base_info_get_name (info);
			if (0 == strncmp (namespace, "GObject", 8)) {
				namespace = "G";
			}
			full_name = g_strconcat (namespace, name, NULL);
			gtype = g_type_from_name (full_name);
			g_free (full_name);
			return gtype ? gtype : G_TYPE_NONE;
		}
	}
	return gtype;
}

static const gchar *
get_package_for_basename (const gchar *basename)
{
	SV **svp;
	HV *basename_to_package =
		get_hv ("Glib::Object::Introspection::_BASENAME_TO_PACKAGE", 0);
	g_assert (basename_to_package);
	svp = hv_fetch (basename_to_package, basename, strlen (basename), 0);
	g_assert (svp && gperl_sv_is_defined (*svp));
	return SvPV_nolen (*svp);
}
