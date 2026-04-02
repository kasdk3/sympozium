// Minimal YAML serializer for Kubernetes resource manifests.

export type YamlValue =
  | string
  | number
  | boolean
  | null
  | undefined
  | YamlValue[]
  | { [key: string]: YamlValue };

function needsQuoting(s: string): boolean {
  if (s === "") return true;
  if (s === "true" || s === "false" || s === "null" || s === "~") return true;
  if (/^[\d.]+$/.test(s)) return true;
  if (/[:{}\[\],&*?|>!%#@`"']/.test(s)) return true;
  if (s.startsWith(" ") || s.endsWith(" ")) return true;
  return false;
}

function quote(s: string): string {
  return needsQuoting(s) ? JSON.stringify(s) : s;
}

function filteredEntries(obj: Record<string, YamlValue>): [string, YamlValue][] {
  return Object.entries(obj).filter(
    ([, v]) => v !== undefined && v !== null && v !== "" && !(Array.isArray(v) && v.length === 0),
  );
}

function isScalar(val: YamlValue): boolean {
  return val === null || val === undefined || typeof val !== "object";
}

/**
 * Serialize a YAML value, appending lines to `out`.
 * `prefix` is the string that goes before this value on the first line (e.g. "  key: " or "- ").
 * `depth` is the indentation depth for subsequent lines of this value.
 */
function emit(out: string[], val: YamlValue, prefix: string, depth: number): void {
  const pad = "  ".repeat(depth);

  if (val === null || val === undefined) {
    out.push(prefix + '""');
    return;
  }
  if (typeof val === "boolean") {
    out.push(prefix + (val ? "true" : "false"));
    return;
  }
  if (typeof val === "number") {
    out.push(prefix + String(val));
    return;
  }
  if (typeof val === "string") {
    if (val.includes("\n")) {
      out.push(prefix + "|");
      for (const line of val.split("\n")) {
        out.push(pad + "  " + line);
      }
      return;
    }
    out.push(prefix + quote(val));
    return;
  }

  if (Array.isArray(val)) {
    if (val.length === 0) {
      out.push(prefix + "[]");
      return;
    }
    // Array value starts on next line
    out.push(prefix.trimEnd().length > 0 ? prefix.trimEnd() : prefix);
    for (const item of val) {
      if (isScalar(item)) {
        emit(out, item, pad + "- ", depth);
      } else if (Array.isArray(item)) {
        emit(out, item, pad + "- ", depth + 1);
      } else if (typeof item === "object" && item !== null) {
        // Object inside array: first key on "- " line, rest indented to match
        const entries = filteredEntries(item as Record<string, YamlValue>);
        if (entries.length === 0) {
          out.push(pad + "- {}");
          continue;
        }
        for (let i = 0; i < entries.length; i++) {
          const [k, v] = entries[i];
          const linePrefix = i === 0 ? pad + "- " : pad + "  ";
          emitKeyValue(out, k, v, linePrefix, depth + 1);
        }
      }
    }
    return;
  }

  if (typeof val === "object") {
    const entries = filteredEntries(val as Record<string, YamlValue>);
    if (entries.length === 0) {
      out.push(prefix + "{}");
      return;
    }
    // Object value starts on next line
    if (prefix.trim()) {
      out.push(prefix.trimEnd());
    }
    for (const [k, v] of entries) {
      emitKeyValue(out, k, v, pad + "  ", depth + 1);
    }
  }
}

function emitKeyValue(out: string[], key: string, val: YamlValue, linePrefix: string, depth: number): void {
  if (isScalar(val)) {
    emit(out, val, linePrefix + key + ": ", depth);
  } else {
    emit(out, val, linePrefix + key + ":", depth);
  }
}

/** Serialize a JS object to a YAML string (top-level). */
export function toYaml(obj: Record<string, YamlValue>): string {
  const out: string[] = [];
  const entries = filteredEntries(obj);
  for (const [k, v] of entries) {
    if (isScalar(v)) {
      emit(out, v, k + ": ", 0);
    } else {
      emit(out, v, k + ":", 0);
    }
  }
  return out.join("\n");
}
