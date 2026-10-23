import { PROTOCOL_VERSION } from "./types";

export function json(value: Record<string, unknown>, status = 200): Response {
  return Response.json(
    { protocolVersion: PROTOCOL_VERSION, ...value },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": "application/json; charset=utf-8",
      },
    },
  );
}

export function problem(status: number, error: string): Response {
  return json({ error }, status);
}
