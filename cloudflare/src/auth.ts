export async function isAuthorized(
  request: Request,
  expectedToken: string,
): Promise<boolean> {
  if (!expectedToken || expectedToken.length < 32) return false;
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return false;
  const supplied = header.slice(7);
  const encoder = new TextEncoder();
  const [actualHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(expectedToken)),
  ]);
  const actual = new Uint8Array(actualHash);
  const expected = new Uint8Array(expectedHash);
  let difference = actual.length ^ expected.length;
  for (
    let index = 0;
    index < Math.min(actual.length, expected.length);
    index++
  ) {
    difference |= actual[index]! ^ expected[index]!;
  }
  return difference === 0;
}
