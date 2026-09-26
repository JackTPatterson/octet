import Foundation

/// Prompt marks (OSC 133) from the shells in Octet's panes, so the session
/// server knows where each command's prompt, output and exit status are:
/// what jump-to-prompt, "copy last output" and a command's time and status
/// are built on. Done the way Ghostty does it: the pane's shell is a small
/// wrapper that points zsh at a `.zshenv` of Octet's (which hands straight
/// back to the user's own files) or adds a fish `vendor_conf.d` file, or
/// starts bash on Octet's rc file (which loads the user's own files), then
/// becomes the real shell. Other shells start untouched.
enum ShellIntegration {
    /// The folder the files live in, under Octet's support folder.
    static func directory(support: URL) -> URL { support.appendingPathComponent("shell-integration", isDirectory: true) }

    /// Writes the files and returns the wrapper to use as the panes' shell.
    /// `shell` is the real one; `login` starts it as a login shell, which is
    /// what a Mac terminal does and what the session server's argv0 trick
    /// can't pass through a script.
    @discardableResult
    static func install(in directory: URL, shell: String, login: Bool) throws -> String {
        let files = FileManager.default
        let zsh = directory.appendingPathComponent("zsh", isDirectory: true)
        let fish = directory.appendingPathComponent("fish/fish/vendor_conf.d", isDirectory: true)
        try files.createDirectory(at: zsh, withIntermediateDirectories: true)
        try files.createDirectory(at: fish, withIntermediateDirectories: true)
        try zshenv.write(to: zsh.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try zshIntegration.write(to: directory.appendingPathComponent("octet.zsh"), atomically: true, encoding: .utf8)
        try fishIntegration.write(to: fish.appendingPathComponent("octet.fish"), atomically: true, encoding: .utf8)
        try bashIntegration.write(to: directory.appendingPathComponent("octet.bash"), atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("octet-shell")
        try wrapperScript(shell: shell, login: login, directory: directory.path)
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    /// folder<TAB>variable<TAB>value per line, shallow folders first so the
    /// wrapper lets deeper ones win. `worktrees` adds a repository's linked
    /// worktrees, which live outside it but use its account.
    static func accountTable(profiles: [AccountProfile], assignments: [AccountAssignment],
                             worktrees: (String) -> [String] = { _ in [] }, userHome: String = NSHomeDirectory()) -> String {
        let byId = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [(folder: String, variable: String, value: String)] = []
        for assignment in assignments {
            guard let profile = byId[assignment.profileId] else { continue }
            for folder in [assignment.folder] + worktrees(assignment.folder) {
                // As named and as it really is: a shell only knows one of them.
                // realpath, not resolvingSymlinksInPath: that one maps
                // /private/var back to /var, the opposite of what a shell sees.
                let real = realpath(folder, nil).map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                } ?? folder
                for path in Set([folder, real]) {
                    rows.append((path, profile.variable, profile.expandedHome(userHome: userHome)))
                }
            }
        }
        return rows.sorted { ($0.folder.count, $0.folder) < ($1.folder.count, $1.folder) }
            .map { "\($0.folder)\t\($0.variable)\t\($0.value)\n" }.joined()
    }

    static func writeAccountTable(_ table: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? table.write(to: directory.appendingPathComponent("accounts.tsv"), atomically: true, encoding: .utf8)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Becomes the real shell with the integration in place. bash, not sh:
    /// `exec -l` is what makes the shell a login shell.
    static func wrapperScript(shell: String, login: Bool, directory: String) -> String {
        """
        #!/bin/bash
        # Octet's pane shell: adds prompt marks, then becomes your shell.
        shell=\(quote(shell))
        dir=\(quote(directory))
        case "${shell##*/}" in
          zsh)
            # Octet's .zshenv puts ZDOTDIR back before your files load.
            if [ -n "${ZDOTDIR+x}" ]; then export OCTET_USER_ZDOTDIR="$ZDOTDIR"; fi
            export ZDOTDIR="$dir/zsh" OCTET_INTEGRATION_DIR="$dir" ;;
          fish)
            export XDG_DATA_DIRS="$dir/fish:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
          bash)
            # Started on Octet's rc file, which loads your own files as a
            # login shell would (or ~/.bashrc), then adds the marks. --rcfile
            # works in every bash, macOS's 3.2 included. Only for an
            # interactive shell with no arguments.
            if [ $# -eq 0 ]; then
              bash_rc=1
              \(login ? "export OCTET_BASH_LOGIN=1" : ":")
            fi ;;
        esac
        # The agent account the folder uses (Octet › Accounts), unless the
        # pane was started with one on purpose. Deeper folders come later
        # and win. (macOS bash 3.2: no associative arrays.)
        if [ -f "$dir/accounts.tsv" ]; then
          ours=" "
          here="$PWD/"
          real="$(pwd -P)/"
          while IFS=$'\t' read -r folder var value; do
            # The folder as named, or as it really is (/var is /private/var).
            case "$here|$real" in
              "$folder"/*|*"|$folder"/*)
                if [ -z "${!var+x}" ] || [ "${ours#* $var }" != "$ours" ]; then
                  export "$var=$value"
                  ours="$ours$var "
                fi ;;
            esac
          done < "$dir/accounts.tsv"
          unset ours here real folder var value
        fi
        # Programs that start "$SHELL" get your shell, not this script.
        export SHELL="$shell"
        if [ -n "${bash_rc:-}" ]; then exec "$shell" --rcfile "$dir/octet.bash" -i; fi
        \(login ? "exec -l \"$shell\" \"$@\"" : "exec \"$shell\" \"$@\"")

        """
    }

    /// Hands zsh back to the user's own files straight away (the rest of
    /// startup reads them from the restored ZDOTDIR), then adds the marks.
    static let zshenv = """
    # Octet shell integration.
    if [[ -n "${OCTET_USER_ZDOTDIR+x}" ]]; then
      export ZDOTDIR="$OCTET_USER_ZDOTDIR"
      unset OCTET_USER_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive && -n "$OCTET_INTEGRATION_DIR" ]]; then
      builtin source "$OCTET_INTEGRATION_DIR/octet.zsh"
    fi

    """

    /// A: prompt start, B: where typing starts, C: the command runs, D: it
    /// finished, with its status. Hooks are added again on the first prompt,
    /// after the user's .zshrc, so frameworks that reset them can't drop them.
    static let zshIntegration = """
    # Octet: OSC 133 prompt marks for zsh.
    typeset -g _octet_running= _octet_status=0
    # First in line, so it sees the command's status, not another hook's.
    _octet_capture() { _octet_status=$? }
    _octet_precmd() {
      if [[ -n $_octet_running ]]; then
        builtin printf '\\e]133;D;%s\\a' $_octet_status
        _octet_running=
      fi
      builtin printf '\\e]133;A\\a'
      [[ $PS1 == *'133;B'* ]] || PS1="$PS1%{$(builtin printf '\\e]133;B\\a')%}"
    }
    _octet_preexec() {
      builtin printf '\\e]133;C\\a'
      _octet_running=1
    }
    _octet_install() {
      autoload -Uz add-zsh-hook
      add-zsh-hook -d precmd _octet_install
      add-zsh-hook precmd _octet_precmd
      add-zsh-hook preexec _octet_preexec
      precmd_functions=(_octet_capture ${precmd_functions:#_octet_capture})
      _octet_precmd
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _octet_install

    """

    /// Bash's rc file: the user's startup files as bash would have read
    /// them, then the marks. The command mark
    /// comes from a DEBUG trap (bash 3.2 on macOS has no PS0), only for the
    /// first command after a prompt, and not if the user already has one.
    static let bashIntegration = """
    # Octet shell integration for bash.
    if [ -n "${OCTET_BASH_LOGIN:-}" ]; then
      unset OCTET_BASH_LOGIN
      [ -r /etc/profile ] && builtin source /etc/profile
      for _octet_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -r "$_octet_file" ]; then builtin source "$_octet_file"; break; fi
      done
      unset _octet_file
    else
      [ -r "$HOME/.bashrc" ] && builtin source "$HOME/.bashrc"
    fi

    _octet_running=
    _octet_at_prompt=
    _octet_prompt_start() {
      local status=$?
      if [ -n "$_octet_running" ]; then
        builtin printf '\\e]133;D;%s\\a' "$status"
        _octet_running=
      fi
      builtin printf '\\e]133;A\\a'
      return $status
    }
    # Last, after anything that rebuilds PS1 (starship, oh-my-bash).
    _octet_prompt_end() {
      [[ $PS1 == *'133;B'* ]] || PS1="$PS1"'\\[\\e]133;B\\a\\]'
      _octet_at_prompt=1
    }
    _octet_preexec() {
      [ -n "$_octet_at_prompt" ] || return 0
      [ -n "${COMP_LINE:-}" ] && return 0
      case "$BASH_COMMAND" in _octet_*) return 0 ;; esac
      _octet_at_prompt=
      builtin printf '\\e]133;C\\a'
      _octet_running=1
    }
    PROMPT_COMMAND="_octet_prompt_start${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _octet_prompt_end"
    [ -z "$(trap -p DEBUG)" ] && trap '_octet_preexec' DEBUG

    """

    static let fishIntegration = """
    # Octet: OSC 133 prompt marks for fish.
    status is-interactive; or exit
    function __octet_prompt --on-event fish_prompt
      set -l last $status
      if set -q __octet_running
        printf '\\e]133;D;%s\\a' $last
        set -e __octet_running
      end
      printf '\\e]133;A\\a'
    end
    function __octet_preexec --on-event fish_preexec
      printf '\\e]133;C\\a'
      set -g __octet_running 1
    end

    """
}
