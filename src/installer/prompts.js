import { createInterface } from "node:readline/promises";

export async function promptAgents(
  supported,
  { input = process.stdin, output = process.stdout } = {},
) {
  const readline = createInterface({ input, output });
  try {
    const answer = await readline.question(
      `Agents (${supported.join(", ")}) [all]: `,
    );
    const values = answer.trim()
      ? answer.split(",").map((value) => value.trim().toLowerCase())
      : supported;
    const invalid = values.filter((value) => !supported.includes(value));
    if (invalid.length) {
      throw new Error(`unsupported agent: ${invalid.join(", ")}`);
    }
    return [...new Set(values)];
  } finally {
    readline.close();
  }
}
