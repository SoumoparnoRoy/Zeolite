// How a failure reads in a log line. A network failure says only "fetch
// failed"; the reason, ENOTFOUND or ECONNRESET, is on its cause.
export function failureOf(error) {
  const code = error?.cause?.code;
  return `${error?.name}: ${error?.message}${code ? ` (${code})` : ""}`;
}
