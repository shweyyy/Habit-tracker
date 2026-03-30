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
    const { workspaceId } = await req.json();
    if (!workspaceId) {
      return json({ error: "workspaceId is required." }, 400);
    }

    const auth = await requireOwner(req, workspaceId);
    if ("error" in auth) return auth.error;

    const [membersResult, invitesResult, usersResult] = await Promise.all([
      auth.admin
        .from("workspace_members")
        .select("user_id, role, created_at")
        .eq("workspace_id", workspaceId)
        .order("created_at", { ascending: true }),
      auth.admin
        .from("invites")
        .select("id, email, role, status, created_at, accepted_at")
        .eq("workspace_id", workspaceId)
        .order("created_at", { ascending: false }),
      auth.admin.auth.admin.listUsers({ page: 1, perPage: 200 })
    ]);

    if (membersResult.error) return json({ error: membersResult.error.message }, 500);
    if (invitesResult.error) return json({ error: invitesResult.error.message }, 500);
    if (usersResult.error) return json({ error: usersResult.error.message }, 500);

    const userMap = new Map((usersResult.data.users ?? []).map((user) => [user.id, user.email ?? ""]));
    const members = (membersResult.data ?? []).map((member) => ({
      ...member,
      email: userMap.get(member.user_id) ?? ""
    }));

    return json({
      members,
      invites: invitesResult.data ?? []
    });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Unexpected error." }, 500);
  }
});
