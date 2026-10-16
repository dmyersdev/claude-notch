// Claude Notch terminal focus.
//
// Claude Notch opens  <scheme>://dmyersdev.claude-notch-terminal-focus/focus?pids=123,456,789
// with the session's process ID and every ancestor's. The integrated terminal whose shell is one of them is the
// one running the session: show it and give it the keyboard. Nothing else is read or sent anywhere.
const vscode = require('vscode');

async function focusTerminal(pids) {
  for (const terminal of vscode.window.terminals) {
    const pid = await terminal.processId;
    if (pid && pids.has(pid)) {
      terminal.show(false);
      await vscode.commands.executeCommand('workbench.action.terminal.focus');
      return true;
    }
  }
  return false;
}

function activate(context) {
  context.subscriptions.push(vscode.window.registerUriHandler({
    async handleUri(uri) {
      if (uri.path !== '/focus') return;
      const query = new URLSearchParams(uri.query);
      const pids = new Set((query.get('pids') || '').split(',').map(Number).filter((n) => Number.isInteger(n) && n > 0));
      if (pids.size > 0) await focusTerminal(pids);
    },
  }));
}

function deactivate() {}

module.exports = { activate, deactivate, focusTerminal };
