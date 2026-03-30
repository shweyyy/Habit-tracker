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
    const { workspaceId, email, redirectTo } = await req.json();
    if (!workspaceId || !email) {
      return json({ error: "workspaceId and email are required." }, 400);
    }

    const auth = await requireOwner(req, workspaceId);
    if ("error" in auth) return auth.error;

    const normalizedEmail = String(email).trim().toLowerCase();

    const { error: inviteUpsertError } = await auth.admin
      .from("invites")
      .upsert({
        workspace_id: workspaceId,
        email: normalizedEmail,
        role: "member",
        status: "pending",
        invited_by: auth.user.id
      }, {
        onConflict: "workspace_id,email,status"
      });

    if (inviteUpsertError) {
      return json({ error: inviteUpsertError.message }, 500);
    }

    const inviteResponse = await auth.admin.auth.admin.inviteUserByEmail(normalizedEmail, {
      redirectTo: typeof redirectTo === "string" && redirectTo ? redirectTo : undefined,
      data: {
        workspace_id: workspaceId,
        invited_as: "member"
      }
    });

    if (inviteResponse.error) {
      return json({ error: inviteResponse.error.message }, 500);
    }

    return json({ ok: true, email: normalizedEmail });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Unexpected error." }, 500);
  }
});
