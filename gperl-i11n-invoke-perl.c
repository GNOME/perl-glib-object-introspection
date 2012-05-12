/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static void
invoke_callback (ffi_cif* cif, gpointer resp, gpointer* args, gpointer userdata)
{
	GPerlI11nPerlCallbackInfo *info;
	GICallableInfo *cb_interface;
	GPerlI11nInvocationInfo iinfo = {0,};
	guint i;
	guint in_inout;
	guint n_return_values, n_returned;
	I32 context;
	dGPERL_CALLBACK_MARSHAL_SP;

	PERL_UNUSED_VAR (cif);

	/* unwrap callback info struct from userdata */
	info = (GPerlI11nPerlCallbackInfo *) userdata;
	cb_interface = (GICallableInfo *) info->interface;

	prepare_perl_invocation_info (&iinfo, cb_interface);

	/* set perl context */
	GPERL_CALLBACK_MARSHAL_INIT (info);

	ENTER;
	SAVETMPS;

	PUSHMARK (SP);

	/* find arguments; use type information from interface to find in and
	 * in-out args and their types, count in-out and out args, and find
	 * suitable converters; push in and in-out arguments onto the perl
	 * stack */
	in_inout = 0;
	for (i = 0; i < iinfo.n_args; i++) {
		GIArgInfo *arg_info = g_callable_info_get_arg (cb_interface, i);
		GITypeInfo *arg_type = g_arg_info_get_type (arg_info);
		GITransfer transfer = g_arg_info_get_ownership_transfer (arg_info);
		GIDirection direction = g_arg_info_get_direction (arg_info);

		iinfo.current_pos = i;

		/* the closure argument, which we handle separately, is marked
		 * by having get_closure == i */
		if (g_arg_info_get_closure (arg_info) == (gint) i) {
			g_base_info_unref ((GIBaseInfo *) arg_info);
			g_base_info_unref ((GIBaseInfo *) arg_type);
			continue;
		}

		dwarn ("arg info: %s (%p)\n"
		       "  direction: %d\n"
		       "  is return value: %d\n"
		       "  is optional: %d\n"
		       "  may be null: %d\n"
		       "  transfer: %d\n",
		       g_base_info_get_name (arg_info), arg_info,
		       g_arg_info_get_direction (arg_info),
		       g_arg_info_is_return_value (arg_info),
		       g_arg_info_is_optional (arg_info),
		       g_arg_info_may_be_null (arg_info),
		       g_arg_info_get_ownership_transfer (arg_info));

		dwarn ("arg type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %s (%d)\n",
		       arg_type,
		       g_type_info_is_pointer (arg_type),
		       g_type_tag_to_string (g_type_info_get_tag (arg_type)), g_type_info_get_tag (arg_type));

		if (direction == GI_DIRECTION_IN ||
		    direction == GI_DIRECTION_INOUT)
		{
			GIArgument arg;
			SV *sv;
			raw_to_arg (args[i], &arg, arg_type);
			SS_arg_to_sv (sv, &arg, arg_type, transfer, &iinfo);
			/* If arg_to_sv returns NULL, we take that as 'skip
			 * this argument'; happens for GDestroyNotify, for
			 * example. */
			if (sv)
				XPUSHs (sv_2mortal (sv));
		}

		if (direction == GI_DIRECTION_INOUT ||
		    direction == GI_DIRECTION_OUT)
		{
			in_inout++;
		}

		g_base_info_unref ((GIBaseInfo *) arg_info);
		g_base_info_unref ((GIBaseInfo *) arg_type);
	}

	/* push user data onto the Perl stack */
	if (info->data)
		XPUSHs (sv_2mortal (SvREFCNT_inc (info->data)));

	PUTBACK;

	/* determine suitable Perl call context */
	context = G_VOID | G_DISCARD;
	if (iinfo.has_return_value) {
		context = in_inout > 0
		  ? G_ARRAY
		  : G_SCALAR;
	} else {
		if (in_inout == 1) {
			context = G_SCALAR;
		} else if (in_inout > 1) {
			context = G_ARRAY;
		}
	}

	/* do the call, demand #in-out+#out+#return-value return values */
	n_return_values = iinfo.has_return_value
	  ? in_inout + 1
	  : in_inout;
	n_returned = info->sub_name
		? call_method (info->sub_name, context)
		: call_sv (info->code, context);
	if (n_return_values != 0 && n_returned != n_return_values) {
		ccroak ("callback returned %d values "
		        "but is supposed to return %d values",
		        n_returned, n_return_values);
	}

	/* call-scoped callback infos are freed by
	 * Glib::Object::Introspection::_FuncWrapper::DESTROY */

	SPAGAIN;

	/* convert in-out and out values and stuff them back into args */
	if (in_inout > 0) {
		SV **returned_values;
		int out_index;

		returned_values = g_new0 (SV *, in_inout);

		/* pop scalars off the stack and put them into the array;
		 * reverse the order since POPs pops items off of the end of
		 * the stack. */
		for (i = 0; i < in_inout; i++) {
			returned_values[in_inout - i - 1] = POPs;
		}

		out_index = 0;
		for (i = 0; i < iinfo.n_args; i++) {
			GIArgInfo *arg_info = g_callable_info_get_arg (cb_interface, i);
			GITypeInfo *arg_type = g_arg_info_get_type (arg_info);
			GIDirection direction = g_arg_info_get_direction (arg_info);
			gpointer out_pointer = * (gpointer *) args[i];

			if (!out_pointer) {
				dwarn ("skipping out arg %d\n", i);
				g_base_info_unref (arg_info);
				g_base_info_unref (arg_type);
				continue;
			}

			if (direction == GI_DIRECTION_INOUT ||
			    direction == GI_DIRECTION_OUT)
			{
				GIArgument tmp_arg;
				GITransfer transfer = g_arg_info_get_ownership_transfer (arg_info);
				gboolean may_be_null = g_arg_info_may_be_null (arg_info);
				gboolean is_caller_allocated = g_arg_info_is_caller_allocates (arg_info);
				if (is_caller_allocated) {
					tmp_arg.v_pointer = out_pointer;
				}
				sv_to_arg (returned_values[out_index], &tmp_arg,
				           arg_info, arg_type,
				           transfer, may_be_null, &iinfo);
				if (!is_caller_allocated) {
					arg_to_raw (&tmp_arg, out_pointer, arg_type);
				}
				out_index++;
			}

			g_base_info_unref (arg_info);
			g_base_info_unref (arg_type);
		}

		g_free (returned_values);
	}

	/* store return value in resp, if any */
	if (iinfo.has_return_value) {
		GIArgument arg;
		GITypeInfo *type_info;
		GITransfer transfer;
		gboolean may_be_null;

		type_info = iinfo.return_type_info;
		transfer = iinfo.return_type_transfer;
		may_be_null = g_callable_info_may_return_null (cb_interface); /* FIXME */

		dwarn ("ret type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %d\n",
		       type_info,
		       g_type_info_is_pointer (type_info),
		       g_type_info_get_tag (type_info));

		sv_to_arg (POPs, &arg, NULL, type_info,
		           transfer, may_be_null, &iinfo);
		arg_to_raw (&arg, resp, type_info);
	}

	PUTBACK;

	clear_perl_invocation_info (&iinfo);

	FREETMPS;
	LEAVE;

	/* FIXME: We can't just free everything here because ffi will use parts
	 * of this after we've returned.
	 *
	 * if (info->free_after_use) {
	 * 	release_callback (info);
	 * }
	 *
	 * Gjs uses a global list of callback infos instead and periodically
	 * frees unused ones.
	 */
}
