import { NextResponse } from "next/server";
import { DEFAULT_INSTALL_SCRIPT_URL } from "@/lib/commandBuilder";

// Ensure this route is always dynamic (never cached at build time)
export const dynamic = "force-dynamic";

/**
 * GET /install
 *
 * Redirects to the raw install.sh script on GitHub, so a site deployed from
 * this repository serves `curl -fsSL https://<site>/install | bash`.
 *
 * The -L flag in curl follows redirects, so this works seamlessly.
 */
export async function GET() {
  // Create redirect response with cache-control headers to prevent caching
  const response = NextResponse.redirect(DEFAULT_INSTALL_SCRIPT_URL, 302);
  response.headers.set("Cache-Control", "no-store, no-cache, must-revalidate");
  response.headers.set("Pragma", "no-cache");
  response.headers.set("Expires", "0");

  return response;
}
