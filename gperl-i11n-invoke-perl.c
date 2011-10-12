static void
invoke_callback (ffi_cif* cif, gpointer resp, gpointer* args, gpointer userdata)
{
	GPerlI11nCallbackInfo *info;
	GICallableInfo *cb_interface;
	int n_args, i;
	int in_inout;
	GITypeInfo *return_type;
	gboolean have_return_type;
	int n_return_values, n_returned;
	I32 context;
	dGPERL_CALLBACK_MARSHAL_SP;

	PERL_UNUSED_VAR (cif);

	/* unwrap callback info struct from userdata */
	info = (GPerlI11nCallbackInfo *) userdata;
	cb_interface = (GICallableInfo *) info->interface;

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
	n_args = g_callable_info_get_n_args (cb_interface);
	for (i = 0; i < n_args; i++) {
		GIArgInfo *arg_info = g_callable_info_get_arg (cb_interface, i);
		GITypeInfo *arg_type = g_arg_info_get_type (arg_info);
		GITransfer transfer = g_arg_info_get_ownership_transfer (arg_info);
		GIDirection direction = g_arg_info_get_direction (arg_info);

		/* the closure argument, which we handle separately, is marked
		 * by having get_closure == i */
		if (g_arg_info_get_closure (arg_info) == i) {
			g_base_info_unref ((GIBaseInfo *) arg_info);
			g_base_info_unref ((GIBaseInfo *) arg_type);
			continue;
		}

		dwarn ("arg info: %p\n"
		       "  direction: %d\n"
		       "  is return value: %d\n"
		       "  is optional: %d\n"
		       "  may be null: %d\n"
		       "  transfer: %d\n",
		       arg_info,
		       g_arg_info_get_direction (arg_info),
		       g_arg_info_is_return_value (arg_info),
		       g_arg_info_is_optional (arg_info),
		       g_arg_info_may_be_null (arg_info),
		       g_arg_info_get_ownership_transfer (arg_info));

		dwarn ("arg type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %d\n",
		       arg_type,
		       g_type_info_is_pointer (arg_type),
		       g_type_info_get_tag (arg_type));

		if (direction == GI_DIRECTION_IN ||
		    direction == GI_DIRECTION_INOUT)
		{
			GIArgument arg;
			raw_to_arg (args[i], &arg, arg_type);
			XPUSHs (sv_2mortal (arg_to_sv (&arg, arg_type, transfer, NULL)));
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

	/* determine suitable Perl call context; return_type is freed further
	 * below */
	return_type = g_callable_info_get_return_type (cb_interface);
	have_return_type =
		GI_TYPE_TAG_VOID != g_type_info_get_tag (return_type);

	context = G_VOID | G_DISCARD;
	if (have_return_type) {
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
	n_return_values = have_return_type
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
		for (i = 0; i < n_args; i++) {
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
				           transfer, may_be_null, NULL);
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
	if (have_return_type) {
		GIArgument arg;
		GITypeInfo *type_info;
		GITransfer transfer;
		gboolean may_be_null;

		type_info = g_callable_info_get_return_type (cb_interface);
		transfer = g_callable_info_get_caller_owns (cb_interface);
		may_be_null = g_callable_info_may_return_null (cb_interface);

		dwarn ("ret type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %d\n",
		       type_info,
		       g_type_info_is_pointer (type_info),
		       g_type_info_get_tag (type_info));

		/* If the callback is supposed to return a GInitiallyUnowned
		 * object then we must enforce GI_TRANSFER_EVERYTHING.
		 * Otherwise, if the Perl code returns a newly created object,
		 * FREETMPS below would finalize it. */
		if (g_type_info_get_tag (type_info) == GI_TYPE_TAG_INTERFACE &&
		    transfer == GI_TRANSFER_NOTHING)
		{
			GIBaseInfo *interface = g_type_info_get_interface (type_info);
			if (GI_IS_REGISTERED_TYPE_INFO (interface) &&
			    g_type_is_a (g_registered_type_info_get_g_type (interface),
			                 G_TYPE_INITIALLY_UNOWNED))
			{
				transfer = GI_TRANSFER_EVERYTHING;
			}
			g_base_info_unref (interface);
		}

		sv_to_arg (POPs, &arg, NULL, type_info,
		           transfer, may_be_null, NULL);
		arg_to_raw (&arg, resp, type_info);

		g_base_info_unref ((GIBaseInfo *) type_info);
	}

	PUTBACK;

	g_base_info_unref ((GIBaseInfo *) return_type);

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
