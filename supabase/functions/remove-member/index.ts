import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    }
  });
}

async function requireOwner(req: Request, workspaceId: string) {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const token = req.headers.get("Authorization")?.replace("Bearer ", "").trim() ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error("Missing Supabase function environment variables.");
  }
  if (!token) {
    return { error: json({ error: "Missing authorization token." }, 401) };
  }

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData.user) {
    return { error: json({ error: "Invalid session." }, 401) };
  }

  const { data: membership, error: membershipError } = await admin
    .from("workspace_members")
    .select("role")
    .eq("workspace_id", workspaceId)
    .eq("user_id", userData.user.id)
    .maybeSingle();

  if (membershipError) {
    return { error: json({ error: membershipError.message }, 500) };
  }
  if (!membership || membership.role !== "owner") {
    return { error: json({ error: "Owner access required." }, 403) };
  }

  return { admin, user: userData.user };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  try {
    const { workspaceId, userId } = await req.json();
    if (!workspaceId || !userId) {
      return json({ error: "workspaceId and userId are required." }, 400);
    }

    const auth = await requireOwner(req, workspaceId);
    if ("error" in auth) return auth.error;
    if (userId === auth.user.id) {
      return json({ error: "You cannot remove yourself as the owner." }, 400);
    }

    const { error } = await auth.admin
      .from("workspace_members")
      .delete()
      .eq("workspace_id", workspaceId)
      .eq("user_id", userId);

    if (error) {
      return json({ error: error.message }, 500);
    }

    return json({ ok: true });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Unexpected error." }, 500);
  }
});
