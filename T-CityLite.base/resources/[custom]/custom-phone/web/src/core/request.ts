// core/request.ts — phone App SDK transport wrapper.
//
// Apps call `requestAppQuery` / `requestAppAction` instead of `fetchNui` so
// every request resolves to the same `{ success, data } | { success, error }`
// envelope. The client-side bridge already answers with that envelope (it
// forwards the server's structured errors, including `timeout`), so this layer
// mainly normalises transport failures into a stable error code.
import { fetchNui } from '../utils/nui';

export interface PhoneRequestOptions {
  timeoutMs?: number;
}

/** Stable envelope shared by every App SDK request. */
export interface PhoneResponse<T = any> {
  success: boolean;
  data?: T;
  error?: string;
  detail?: string;
}

/** Errors produced by this transport wrapper (server codes pass through). */
export type PhoneRequestError = 'timeout' | 'query_failed' | 'action_failed' | 'no_response';

export async function phoneRequest<T = any>(
  event: string,
  payload: Record<string, unknown> = {},
  { timeoutMs = 9000 }: PhoneRequestOptions = {},
): Promise<PhoneResponse<T>> {
  // Preserve the historical per-callback fallback codes.
  const fallbackError = event === 'appAction' ? 'action_failed' : 'query_failed';
  try {
    const res = await fetchNui<PhoneResponse<T>>(event, payload, { timeoutMs });
    if (!res || typeof res !== 'object') {
      return { success: false, error: 'no_response' };
    }
    if (res.success) {
      return { success: true, data: (res.data ?? ({} as T)) };
    }
    // The client bridge owns the `timeout` code (8s request_id deadline); it is
    // forwarded unchanged along with every other server error code.
    const error = typeof res.error === 'string' && res.error ? res.error : fallbackError;
    return typeof res.detail === 'string' && res.detail
      ? { success: false, error, detail: res.detail }
      : { success: false, error };
  } catch (err) {
    // fetchNui aborts a hung NUI callback, and a dropped callback rejects the
    // fetch. Both have always surfaced to the apps as `query_failed` for
    // queries and `action_failed` for actions.
    console.error(`Phone request failed: ${event}`, err);
    return { success: false, error: fallbackError };
  }
}

export function requestAppQuery<T = any>(
  appId: string,
  query: string,
  params: Record<string, unknown> = {},
  options?: PhoneRequestOptions,
): Promise<PhoneResponse<T>> {
  return phoneRequest<T>('appQuery', { app_id: appId, query, params }, options);
}

export function requestAppAction<T = any>(
  appId: string,
  action: string,
  params: Record<string, unknown> = {},
  options?: PhoneRequestOptions,
): Promise<PhoneResponse<T>> {
  return phoneRequest<T>('appAction', { app_id: appId, action, params }, options);
}
