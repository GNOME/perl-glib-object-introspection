/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static gpointer
sv_to_callback (GIArgInfo * arg_info,
                GITypeInfo * type_info,
                SV * sv,
                GPerlI11nInvocationInfo * invocation_info)
{
	GPerlI11nCallbackInfo *callback_info;

	GSList *l;
	for (l = invocation_info->callback_infos; l != NULL; l = l->next) {
		GPerlI11nCallbackInfo *callback_info = l->data;
		if (invocation_info->current_pos == callback_info->notify_pos) {
			dwarn ("      destroy notify for callback %p\n",
			       callback_info);
			/* Decrease the dynamic stack offset so that this
			 * destroy notify callback doesn't consume any Perl
			 * value from the stack. */
			invocation_info->dynamic_stack_offset--;
			return release_callback;
		}
	}

	callback_info = create_callback_closure (type_info, sv);
	callback_info->data_pos = g_arg_info_get_closure (arg_info);
	callback_info->notify_pos = g_arg_info_get_destroy (arg_info);
	callback_info->free_after_use = FALSE;

	dwarn ("      callback data at %d, destroy at %d\n",
	       callback_info->data_pos, callback_info->notify_pos);

	switch (g_arg_info_get_scope (arg_info)) {
	    case GI_SCOPE_TYPE_CALL:
		dwarn ("      callback has scope 'call'\n");
		invocation_info->free_after_call
			= g_slist_prepend (invocation_info->free_after_call,
			                   callback_info);
		break;
	    case GI_SCOPE_TYPE_NOTIFIED:
		dwarn ("      callback has scope 'notified'\n");
		/* This case is already taken care of by the notify
		 * stuff above */
		break;
	    case GI_SCOPE_TYPE_ASYNC:
		dwarn ("      callback has scope 'async'\n");
		/* FIXME: callback_info->free_after_use = TRUE; */
		break;
	    default:
		ccroak ("unhandled scope type %d encountered",
		       g_arg_info_get_scope (arg_info));
	}

	invocation_info->callback_infos =
		g_slist_prepend (invocation_info->callback_infos,
		                 callback_info);

	dwarn ("      returning closure %p from info %p\n",
	       callback_info->closure, callback_info);
	return callback_info->closure;
}

static gpointer
sv_to_callback_data (SV * sv,
                     GPerlI11nInvocationInfo * invocation_info)
{
	GSList *l;
	if (!invocation_info)
		return NULL;
	for (l = invocation_info->callback_infos; l != NULL; l = l->next) {
		GPerlI11nCallbackInfo *callback_info = l->data;
		if (callback_info->data_pos == invocation_info->current_pos) {
			dwarn ("    user data for callback %p\n",
			       callback_info);
			attach_callback_data (callback_info, sv);
			return callback_info;
		}
	}
	return NULL;
}
