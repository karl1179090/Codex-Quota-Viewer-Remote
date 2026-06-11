import { describe, expect, test } from "vitest";

import {
  buildRemoteArchiveCommand,
  buildSSHCommandArgs,
} from "../../src/server/services/remote-session-importer";

describe("remote-session-importer", () => {
  test("quotes multiline scripts as one remote sh -c argument", () => {
    const script = `
CODEX_HOME_INPUT='~/.codex'
case "$CODEX_HOME_INPUT" in
  "~/"*) CODEX_HOME="$HOME/\${CODEX_HOME_INPUT#~/}" ;;
esac
tar -czf - -C "$CODEX_HOME/sessions" .
`.trim();

    const args = buildSSHCommandArgs("82", script);

    expect(args.slice(0, 7)).toEqual([
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "82",
      "sh",
      "-c",
    ]);
    expect(args[7]).toMatch(/^'.*'$/s);
    expect(args[7]).toContain("CODEX_HOME_INPUT");
    expect(args[7]).toContain("tar -czf -");
  });

  test("expands tilde-prefixed Codex homes without preserving the tilde", () => {
    const command = buildRemoteArchiveCommand("~/.codex");

    expect(command).toContain('CODEX_HOME_INPUT=\'~/.codex\'');
    expect(command).toContain('CODEX_HOME="$HOME/${CODEX_HOME_INPUT#\\~/}"');
    expect(command).not.toContain('CODEX_HOME="$HOME/${CODEX_HOME_INPUT#~/}"');
  });
});
