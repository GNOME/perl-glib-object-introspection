/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static void
generic_class_init (GIObjectInfo *info, const gchar *target_package, gpointer class)
{
	GIStructInfo *struct_info;
	gint n, i;
	struct_info = g_object_info_get_class_struct (info);
	n = g_object_info_get_n_vfuncs (info);
	for (i = 0; i < n; i++) {
		GIVFuncInfo *vfunc_info;
		const gchar *vfunc_name;
		GIFieldInfo *field_info;
		gint field_offset;
		GITypeInfo *field_type_info;
		gchar *perl_method_name;
		GPerlI11nPerlCallbackInfo *callback_info;

		vfunc_info = g_object_info_get_vfunc (info, i);
		vfunc_name = g_base_info_get_name (vfunc_info);

		perl_method_name = g_ascii_strup (vfunc_name, -1);
		{
			/* If there is no implementation of this vfunc at INIT
			 * time, we assume that the intention is to provide no
			 * implementation and we thus skip setting up the class
			 * struct member. */
			HV * stash = gv_stashpv (target_package, 0);
			GV * slot = gv_fetchmethod (stash, perl_method_name);
			if (!slot) {
				g_base_info_unref (vfunc_info);
				g_free (perl_method_name);
				continue;
			}
		}

		/* FIXME: g_vfunc_info_get_offset does not seem to work here. */
		field_info = get_field_info (struct_info, vfunc_name);
		g_assert (field_info);
		field_offset = g_field_info_get_offset (field_info);
		field_type_info = g_field_info_get_type (field_info);

		callback_info = create_perl_callback_closure_for_named_sub (
		                  field_type_info, perl_method_name);
		dwarn ("installing vfunc %s as %s at offset %d (vs. %d) inside %p\n",
		       vfunc_name, perl_method_name,
		       field_offset, g_vfunc_info_get_offset (vfunc_info),
		       class);
		G_STRUCT_MEMBER (gpointer, class, field_offset) = callback_info->closure;

		g_base_info_unref (field_type_info);
		g_base_info_unref (field_info);
		g_base_info_unref (vfunc_info);
	}
	g_base_info_unref (struct_info);
}
