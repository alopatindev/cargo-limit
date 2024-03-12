# cargo-limit
[![Crates.io](https://img.shields.io/crates/v/cargo-limit)](https://crates.io/crates/cargo-limit)
[![Crates.io](https://img.shields.io/crates/d/cargo-limit)](https://crates.io/crates/cargo-limit)
[![Awesome](https://gist.githubusercontent.com/alopatindev/56009d77564991c5474197f3aba85670/raw/cc4370f645d7ad40defcf8d1d14025dfa8726fd2/awesome.svg)](https://github.com/rust-unofficial/awesome-rust#build-system)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-%E2%9D%A4-%23db61a2.svg?&logo=github&logoColor=white&labelColor=181717&style=flat-square)](#Support)

## Description

🚀 Cargo with less noise:
- errors have highest priority
    - they never appear in the middle of warnings
    - **warnings are skipped** by default until errors are fixed
    - external [path dependencies'](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html#specifying-path-dependencies) warnings are skipped by default
- all messages come **in reversed order** by default
    - to avoid extra scrolling
- messages are grouped by filenames
- number of messages can be limited
- after encountering **first error** the rest of **build time is limited** by default
- files can be **[automatically opened](#text-editoride-integrations) in your text editor on affected lines**

Initially this project was a workaround for **[this issue](https://github.com/rust-lang/rust/issues/27189), which was closed with no adequate solution**.

Check out [🎙️  Rustacean Station podcast episode](https://rustacean-station.org/episode/alexander-lopatin/) for more.

[![asciicast](https://gist.githubusercontent.com/alopatindev/2376b843dffef8d1a3af7ef44aef67be/raw/bfa15c2221cb5be128857068dd786374f9f6f186/cargo-limit-demo.svg)](https://asciinema.org/a/441673)

## Installation

<a href="https://repology.org/project/cargo-limit/versions"><img align="right" src="https://repology.org/badge/vertical-allrepos/cargo-limit.svg" alt="Packaging status"></a>

### From crates.io
```
cargo install --locked cargo-limit
```

### From git
```
cargo install --locked --force --git https://github.com/cargo-limit/cargo-limit
```

## Usage
Run any of these in your project directory:
```
cargo lbench
cargo lbuild
cargo lcheck
cargo lclippy
cargo ldoc
cargo lfix
cargo lrun
cargo lrustc
cargo lrustdoc
cargo ltest
```

Also `llcheck`, `llrun`, etc. to **auto-open text editor for warnings** as well, not just for errors.

This tool is especially useful in combination with [cargo-watch](https://crates.io/crates/cargo-watch).

<details>
<summary><b>💡 Environment Variables 👁️</b></summary>
<p>

### CARGO_MSG_LIMIT
- limit compiler messages number
- `0` means no limit, which is default

### CARGO_TIME_LIMIT
- `cargo` execution time limit in seconds after encountering first compiling error
- `1` is default
- `0` means no limit

### CARGO_ASC
- show compiler messages in ascending order
- `false` is default

### CARGO_FORCE_WARN
- show warnings even if errors still exist
- `false` is default

### CARGO_DEPS_WARN
- show external path dependencies' warnings
- `false` is default

### CARGO_EDITOR
- opens affected files in external app
    - see [neovim integration](#text-editoride-integrations)
- empty (`""`) means don't run external app
- `"_cargo-limit-open-in-nvim"` is default

</p>
</details>

## Text Editor/IDE integrations
<details>
<summary><b>💡 Neovim Plugin 👁️</b></summary>
<p>

Requires `nvim >= 0.7.0` and `git` to be installed.

This plugin is [LSP](https://microsoft.github.io/language-server-protocol/)-independent, **it will keep working even when [rust-analyzer](https://rust-analyzer.github.io/) fails** to produce diagnostics!

### Using **[vim-plug](https://github.com/junegunn/vim-plug#neovim):**
```viml
Plug 'alopatindev/cargo-limit', { 'do': 'cargo install --locked cargo-limit nvim-send' }
```

and run
```bash
nvim +PlugInstall +UpdateRemotePlugins +qa
```

<details>
<summary><b>💡 Using other Neovim Plugin Managers 👁️</b></summary>
<p>

### [lazy.nvim](https://github.com/folke/lazy.nvim)
```lua
{ 'alopatindev/cargo-limit', build = 'cargo install --locked cargo-limit nvim-send' },
```

and run
```bash
nvim --headless "+Lazy! sync" +qa
```

### [paq-nvim](https://github.com/savq/paq-nvim):
```lua
{ 'alopatindev/cargo-limit', build = ':!cargo install --locked cargo-limit nvim-send' },
```

and run
```bash
nvim +PaqSync +qa
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim):
```lua
{ use 'alopatindev/cargo-limit', run = ':!cargo install --locked cargo-limit nvim-send' }
```

and run
```bash
nvim +PackerUpdate +qa
```

### [dein](https://github.com/Shougo/dein.vim):
```viml
call dein#add('alopatindev/cargo-limit', { 'rev': 'master', 'hook_post_update': '!cargo install --locked cargo-limit nvim-send' })
```

and run
```bash
nvim --cmd '!call dein#install()'
```

</p>
</details>

### Optionally: F2 to save, F2 again to jump to next affected line
```viml
" TODO: naming
fun! SaveAllFilesOrOpenNextLocation() abort
  " TODO: os-dependant? let l:workspace_root = g:CargoLimitWorkspaceRoot() . '/'
  let l:workspace_root = g:CargoLimitWorkspaceRoot()
  let l:all_rust_files_are_saved = v:true

  for i in getbufinfo({'bufmodified': 1})
    if i.name =~# l:workspace_root && !(i.name =~# '/BqfPreviewScrollBar$')
      let l:all_rust_files_are_saved = v:false
      break
    endif
  endfor

  if l:all_rust_files_are_saved && exists('*CargoLimitOpenNextLocation')
    call g:CargoLimitOpenNextLocation()
  endif
  execute 'wa!'
endf

nmap <F1> :call g:CargoLimitOpenPrevLocation()<Enter>
vmap <F1> <Esc>:call g:CargoLimitOpenPrevLocation()<Enter>v
imap <F1> <Esc>:call g:CargoLimitOpenPrevLocation()<Enter>i

nmap <F2> :call SaveAllFilesOrOpenNextLocation()<cr>
vmap <F2> <esc>:call SaveAllFilesOrOpenNextLocation()<cr>v
imap <F2> <esc>:call SaveAllFilesOrOpenNextLocation()<cr>i
```

### Optionally: less verbose messages
```viml
let g:CargoLimitVerbosity = 2 " warnings level
```

<details>
<summary><b>💡 Test the plugin! 👁️</b></summary>
<p>

1. Open two terminals (or tmux windows, etc.)
2. `cd your/project/directory` in both of them
3. Run `nvim` in one of them
4. Run `cargo lrun` in the other
5. In case of compiling errors `nvim` opens new or existing tabs with the files on affected lines and columns
6. Fix the error, save the file and `nvim` will jump to the next error location
7. `cargo llrun` (`cargo llcheck`, etc.) will open them in case of warnings as well.

</p>
</details>

<details>
<summary><b>⚠️ Known Limitations! 👁️</b></summary>
<p>

### 1. Auto-jumps work only if
- current **mode is normal**
- current buffer is either **empty or contains some existing and unmodified** (saved) file

This is by design, in order to **not disrupt** from active text editing or file navigation process.

Also auto-jump may not happen to affected line that supposed to be **already modified/fixed** (until you rerun `cargo ll{check,run,etc.}`).

### 2. Before running `nvim`: Current Directory should be Project (sub)directory
- that's required so **cargo-limit** could [figure out](https://github.com/cargo-limit/cargo-limit/issues/30#issuecomment-1219793195) which exact `nvim` instance should be controlled
- only **first `nvim` instance** with current project (sub)directory will be **controlled by cargo-limit**.

</p>
</details>

## Customizations
Add **custom update handlers** to your `init.vim` if you want other Neovim behavior.

<details>
<summary><b>💡 See examples for Neovim! 👁️</b></summary>
<p>

### Open Files in Buffers Instead of Tabs
```viml
fun! g:CargoLimitUpdate(editor_data)
  let l:current_file = resolve(expand('%:p'))
  if l:current_file != '' && !filereadable(l:current_file)
    return
  endif
  for location in reverse(a:editor_data.locations)
    let l:path = fnameescape(location.path)
    if mode() == 'n' && &l:modified == 0
      execute 'edit ' . l:path
      call cursor((location.line), (location.column))
    else
      break
    endif
  endfor
endf
```

### Populate a QuickFix List
```viml
set errorformat =%f:%l:%c:%m

fun! g:CargoLimitUpdate(editor_data)
  if a:editor_data['corrected_locations']
    let l:quickfix_list_is_open = v:false
    for win in getwininfo()
      if win.quickfix
        let l:quickfix_list_is_open = v:true
        break
      endif
    endfor

    if !l:quickfix_list_is_open
      return
    endif
  endif

  let l:winnr = winnr()

  cgetexpr []
  for location in a:editor_data['locations']
    caddexpr location['path'] . ':' . location['line'] . ':' . location['column'] . ':' . location['message']
  endfor

  if empty(a:editor_data['locations'])
    cclose
  else
    copen
  endif

  if l:winnr !=# winnr()
    wincmd p
  endif
endf
```

</p>
</details>

</p>
</details>

<details>
<summary><b>💡 Other Text Editors/IDEs 👁️</b></summary>
<p>

**cargo-limit** can run external app/script and provide affected locations to stdin in the following JSON format:
```json
{
  "protocol_version": "0.0.11",
  "workspace_root": "/full/path/to/project",
  "locations": [
    {
      "path": "/full/path/to/project/file.rs",
      "line": 4,
      "column": 1,
      "message": "unused import: `diagnostic::DiagnosticSpan`",
      "level": "warning"
    }
  ],
  "corrected_locations": false
}
```

Theoretically this can be used for any text editor or IDE, especially if it supports client/server communication. To do that you need a **wrapper app/script** that parses the `locations` and gives them to the text editor or IDE client.

<details>
<summary><b>💡 Example: Gedit! 👁️</b></summary>
<p>

1. Install [`jq`](https://stedolan.github.io/jq/download/)
2. Create `open-in-gedit.sh`:
```bash
#!/bin/bash

jq --raw-output '.locations |= unique_by(.path) | .locations[] | [
    "gedit",
    .path,
    "+" + (.line | tostring) + ":" + (.column | tostring),
    "&"
] | join(" ")' | bash
```
3. `chmod +x open-in-gedit.sh`
4. Set `CARGO_EDITOR=/path/to/open-in-gedit.sh` environment variable
5. Run `cargo lrun` in your project directory
6. In case of compiling errors `open-in-gedit.sh` will open files in `gedit` on affected lines and columns
7. `cargo llrun` (`cargo llcheck`, etc.) will open them in case of warnings as well.

</p>
</details>

</p>
</details>

## Similar Projects/Inspirations
- [bacon](https://github.com/Canop/bacon) is a background rust code checker
- [cargo-firstpage](https://github.com/cecton/cargo-firstpage) shows only the first page of rustc output
- [ograc](https://gitlab.com/lirnril/ograc) like cargo, but backwards

## Support
If this project improved your workflow — please consider:
- pressing ⭐
- sharing this project with your friends/colleges
- buying me some ~~coffee~~ veggies 🥕

---

Your donations will help me allocate more time to resolve [issues](https://github.com/cargo-limit/cargo-limit/issues) and to **finish all the [planned features](https://github.com/cargo-limit/cargo-limit/projects/1?fullscreen=true)**! ❤️

- **Bitcoin** (BTC) `1Afgvdz1oPaugFcLgDaAzCYYdHexV6tTvH`

- **TRON** (TRX, USDT-TRC20, etc.) `TVxE2HyryNyNReMvw9HRQ3BkYePCszXSrc`

- **Ethereum** (ETH, DAI, etc.) `0xa879cdb1d7d859e6e425f8e50c4ee49f4b3a7b06`

- **[PayPal](https://paypal.me/alopatindev)**

- **[Open Collective](https://opencollective.com/cargo-limit)**

- **[Patreon](https://www.patreon.com/checkout/alopatindev/9785189)**

- **[Liberapay](https://liberapay.com/alopatindev)**

- **[Ko-fi](https://ko-fi.com/alopatindev)**

---

Also thanks everyone for code contributions and bug reporting. Special thanks to [Casey Rodarmor](https://github.com/casey) for providing VimL code for quickfix populator and [Otavio Salvador](https://github.com/otavio) for [NixOS package](https://search.nixos.org/packages?show=cargo-limit)!

## License
MIT/Apache-2.0
