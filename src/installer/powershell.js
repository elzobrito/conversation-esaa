import { spawnSync } from "node:child_process";

export function runPowerShell(script, args, { executable = "pwsh" } = {}) {
  const result = spawnSync(
    executable,
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, ...args],
    {
      encoding: "utf8",
      shell: false,
      windowsHide: true,
    },
  );
  if (result.error) {
    throw new Error(`PowerShell 7 is required: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || "").trim();
    throw new Error(`PowerShell bootstrap failed (${result.status}): ${detail}`);
  }
  return result.stdout;
}
