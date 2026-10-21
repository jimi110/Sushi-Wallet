// Borra la identidad ANÓNIMA del propio llamante cuando ya no figura en ninguna sala Wrapped.
// La clave service_role vive solo aquí (variable de entorno de la Edge Function), nunca en el navegador.
// Despliegue:  supabase functions deploy wr-delete-identity
// (SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY las inyecta Supabase automáticamente.)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "not_authenticated" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Solo la propia identidad, solo si es anónima.
  const { data: u, error: ue } = await admin.auth.getUser(jwt);
  if (ue || !u.user) return json({ error: "not_authenticated" }, 401);
  if (!u.user.is_anonymous) return json({ error: "not_anonymous" }, 403);

  // Solo cuando es seguro: sin salas ni recompensas pendientes.
  const { data: busy, error: be } = await admin.rpc("wr_user_in_any_room", { p_user: u.user.id });
  if (be) return json({ error: "check_failed" }, 500);
  if (busy) return json({ deleted: false, reason: "still_in_room" });

  const { error: de } = await admin.auth.admin.deleteUser(u.user.id);
  if (de) return json({ error: "delete_failed" }, 500);
  return json({ deleted: true });
});
