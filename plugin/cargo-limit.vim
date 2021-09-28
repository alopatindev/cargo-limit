"TODO: escape windows username? probably no
"TODO: detect whether cargo installed?
"TODO: stderr => print error?

let s:data_chunks = []

function! s:on_cargo_metadata_stdout(_job_id, data, event)
  if a:event == 'stdout'
    call add(s:data_chunks, join(a:data, ''))
  elseif a:event == 'exit'
    let l:stdout = join(s:data_chunks, '')
    if len(l:stdout) > 0
      let l:metadata = json_decode(l:stdout)
      let l:workspace_root = get(l:metadata, 'workspace_root')
      let l:escaped_workspace_root = substitute(workspace_root, '[/\\:]', '%', 'g')
      let l:server_address = s:create_server_address(l:escaped_workspace_root)
      if !filereadable(l:server_address)
        call serverstart(l:server_address)
      endif
    endif
  endif
endfunction

function! s:create_server_address(escaped_workspace_root)
  let l:prefix = 'nvim-cargo-limit-'
  if has('win32')
    return '\\.\pipe\' . l:prefix . $USERNAME . '-' . a:escaped_workspace_root
  elseif has('unix')
    let l:server_address_dir =  '/tmp/' . l:prefix . $USER
    call mkdir(l:server_address_dir, 'p', 0700)
    let l:server_address = l:server_address_dir . '/' . a:escaped_workspace_root
    return l:server_address
  else
    throw 'unsupported OS'
  endif
endfunction

function! s:starts_with(longer, shorter) abort
  return a:longer[0 : len(a:shorter) - 1] ==# a:shorter
endfunction

" TODO: rewrite
" fn escape_for_neovim_command(path: &str) -> String {
"     path.replace(r"\", r"\\")
"         .replace(r#"""#, r#"\""#)
"         .replace("'", r"\'")
"         .replace("[", r"\[")
"         .replace("<", r"<LT>")
"         .replace(" ", r"\ ")
" }

function! CargoLimit_open_in_new_or_existing_tabs(editor_data)
  " TODO: don't handle this stuff if
  " + current mode is not normal
  " + or no file from project is currently open and active (which means it's netrw/fzf search/etc. is going on)
  "   - echo expand('%:p')
  " + or current file is unsaved (which means it's probably been edited using normal mode)
  "   - echo &l:modified
  " ? or normal mode input buffer (typeahead buffer?) is not empty (for instance we're in the middle on `2G` command)
  " + or command line buffer is not empty (or just : is in the input)
  "   - filetype? rightleft? modifiable? buftype? (nofile), swapfile? getcmdwintype()?
  " ? or search mode is active (/ or ?)
  " ? or filter commands is active? (!)
  " ? other commands (>/=@- ?)

  let l:editor_data = json_decode(a:editor_data)
  let l:initial_file = resolve(expand('%:p'))
  let l:initial_file_is_part_of_project = s:starts_with(l:initial_file, resolve(l:editor_data.workspace_root)) && filereadable(l:initial_file)

  for source_file in l:editor_data.files
    if l:initial_file_is_part_of_project && mode() == 'n' && &l:modified == 0
      "TODO: escape path here for the command? (escape_for_neovim_command)
      let l:path = (l:editor_data.workspace_root) . '/' . (source_file.relative_path)
      execute 'tab drop ' . l:path
      call cursor((source_file.line), (source_file.column))
    endif
  endfor
endfunction

if has('nvim')
  call jobstart(['cargo', 'metadata', '--quiet', '--format-version=1'], {
  \ 'on_stdout': function('s:on_cargo_metadata_stdout'),
  \ 'on_exit': function('s:on_cargo_metadata_stdout'),
  \ })
else
  throw 'unsupported text editor'
endif

" vim:shiftwidth=2 softtabstop=2 tabstop=2
