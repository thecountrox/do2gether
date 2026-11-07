/** Server time in integer ms since epoch. Every timestamp the server emits comes from here. */
export function serverNow(): number {
  return Date.now();
}
