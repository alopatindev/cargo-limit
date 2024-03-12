" TODO: enable linter: https://github.com/Vimjas/vint + https://github.com/Vimjas/vint/issues/367
" FIXME: regression? jump should not happen while I'm editing a file
" TODO: open current location before jumping to prev location? in case of the only location that we moved away

fun! s:main() abort
  const MIN_NVIM_VERSION = '0.7.0'

  if has('nvim')
    if !has('nvim-' . MIN_NVIM_VERSION)
      throw 'unsupported nvim version, expected >=' . MIN_NVIM_VERSION
    endif

    if !exists('g:CargoLimitVerbosity')
      let g:CargoLimitVerbosity = 3 " info level
    endif
    let s:data_chunks = []
    let s:editor_data = {'locations': []}
    let s:workspace_root = v:null
    let s:location_index = v:null
    let s:edited_locations = {}
    let s:temp_sources_dir = v:null
    let s:deprecated_cargo_limit_open = v:null
    call jobstart(['cargo', 'metadata', '--quiet', '--format-version=1'], {
    \ 'on_stdout': function('s:on_cargo_metadata'),
    \ 'on_stderr': function('s:on_cargo_metadata'),
    \ 'on_exit': function('s:on_cargo_metadata'),
    \ })
  else
    throw 'unsupported text editor'
  endif
endf

fun! s:on_cargo_metadata(_job_id, data, event) abort
  if a:event ==# 'stdout'
    call add(s:data_chunks, join(a:data, ''))
  elseif a:event ==# 'stderr' && type(a:data) ==# v:t_list
    let l:stderr = trim(join(a:data, "\n"))
    if len(l:stderr) > 1 && !s:contains_str(l:stderr, 'could not find `Cargo.toml`')
      call s:log_error('cargo metadata failed', l:stderr, !empty(l:stderr), !s:contains_str(l:stderr, 'could not find `Cargo.toml`'), len(l:stderr), l:stderr !~# 'could not find `Cargo.toml`', 'stderr="' . l:stderr . '"') " TODO
    endif
  elseif a:event ==# 'exit'
    let l:stdout = trim(join(s:data_chunks, ''))
    if !empty(l:stdout)
      let l:metadata = json_decode(l:stdout)
      let s:workspace_root = get(l:metadata, 'workspace_root')
      let l:escaped_workspace_root = s:escape_path(s:workspace_root)
      call s:start_server(l:escaped_workspace_root)
    endif
  endif
endf

fun! s:start_server(escaped_workspace_root) abort
  const TEMP_DIR_PREFIX = 'nvim-cargo-limit-'
  const SOURCES = '.sources'

  if has('unix')
    let l:server_address = '/tmp/' . TEMP_DIR_PREFIX . $USER . '/' . a:escaped_workspace_root
    let s:temp_sources_dir = l:server_address . SOURCES
    call s:maybe_delete_dead_unix_socket(l:server_address)
  elseif has('win32')
    const SERVER_ADDRESS_POSTFIX = TEMP_DIR_PREFIX . $USERNAME . '-' . a:escaped_workspace_root
    let l:server_address = '\\.\pipe\' . SERVER_ADDRESS_POSTFIX
    let s:temp_sources_dir = $TEMP . '\' . SERVER_ADDRESS_POSTFIX . SOURCES
  else
    throw 'unsupported OS'
  endif

  if !filereadable(l:server_address)
    call s:recreate_temp_sources_dir()
    call s:maybe_setup_handlers()
    call serverstart(l:server_address)
    call s:log_info('ready')
  endif
endf

function s:validate_plugin_version(editor_data)
  const PLUGIN_VERSION = '0.0.11'

  let l:crate_version = v:null
  let l:version_matched = v:false
  let l:crate_message_postfix = ' > crate version'
  if exists('a:editor_data.protocol_version')
    let l:crate_version = a:editor_data.protocol_version
    let l:version_matched = l:crate_version == PLUGIN_VERSION
    let l:crate_message_postfix = ' != crate ' . l:crate_version
  endif

  if !l:version_matched
    call s:log_info('version mismatch, plugin ' . PLUGIN_VERSION . l:crate_message_postfix)
  endif
endf

fun! s:maybe_setup_handlers() abort
  augroup CargoLimitAutocommands
    autocmd!
    autocmd VimLeavePre * call s:recreate_temp_sources_dir() " TODO: or just remove the dir?
    autocmd BufWritePost *.rs call s:on_buffer_write()
  augroup END

  if exists('*CargoLimitOpen')
    let s:deprecated_cargo_limit_open = funcref('g:CargoLimitOpen')
    call s:log_warn('g:CargoLimitOpen is deprecated, please migrate to g:CargoLimitUpdate: https://github.com/alopatindev/cargo-limit#text-editoride-integrations')
  endif

  fun! g:CargoLimitOpen(editor_data) abort
    call s:validate_plugin_version(a:editor_data)

    let s:editor_data = a:editor_data
    let s:location_index = -1
    let s:edited_locations = {}

    if s:deprecated_cargo_limit_open !=# v:null
      call s:downgrade_editor_data_format()
      call s:deprecated_cargo_limit_open(s:editor_data)
    endif

    call s:upgrade_editor_data_format()

    if s:deprecated_cargo_limit_open !=# v:null
      return
    endif

    call s:copy_affected_files_to_temp()

    if !exists('*CargoLimitUpdate')
      fun! g:CargoLimitUpdate(editor_data) abort
        let l:current_file = s:current_file()
        if (l:current_file !=# '' && !filereadable(l:current_file)) || empty(s:editor_data.locations)
          return
        endif

        if !a:editor_data.corrected_locations
          call s:open_all_locations_in_reverse_deduplicated_by_paths()
          call s:update_next_unique_location_index()
        end
      endf
    endif

    let s:editor_data.corrected_locations = v:false
    call g:CargoLimitUpdate(s:editor_data)
  endf

  " TODO: is it useful to define global function like that?
  fun! g:CargoLimitOpenNextLocation() abort
    echomsg ''
    call s:open_next_location_in_new_or_existing_tab()
  endf

  " TODO: is it useful to define global function like that?
  fun! g:CargoLimitOpenPrevLocation() abort
    echomsg ''
    call s:open_prev_location_in_new_or_existing_tab()
  endf
endf

fun! s:downgrade_editor_data_format() abort
  if exists('s:editor_data.locations')
    let s:editor_data.files = s:editor_data.locations
    call remove(s:editor_data, 'locations')
  endif
endf

fun! s:upgrade_editor_data_format() abort
  if exists('s:editor_data.files')
    let s:editor_data.locations = s:editor_data.files
    call remove(s:editor_data, 'files')
  endif
  if !exists('s:editor_data.corrected_locations')
    let s:editor_data.corrected_locations = v:false
  endif
endf

fun! s:copy_affected_files_to_temp() abort
  call s:recreate_temp_sources_dir()

  let l:paths = {}
  for l:index in range(0, len(s:editor_data.locations) - 1)
    let l:paths[s:editor_data.locations[l:index].path] = v:true
  endfor

  for l:path in keys(l:paths)
    call s:maybe_copy_to_temp(l:path)
  endfor
endf

" TODO: rename
fun! s:open_all_locations_in_reverse_deduplicated_by_paths() abort
  let l:path_to_location_index = {}
  for l:index in range(len(s:editor_data.locations) - 1, 0, -1)
    let l:path_to_location_index[s:editor_data.locations[l:index].path] = l:index
  endfor

  redraw!

  for l:index in range(len(s:editor_data.locations) - 1, 0, -1)
    let l:path = s:editor_data.locations[l:index].path
    if !has_key(l:path_to_location_index, l:path)
      continue
    elseif mode() ==# 'n' && &l:modified ==# 0
      let l:location_index = l:path_to_location_index[l:path]
      call remove(l:path_to_location_index, l:path)
      call s:jump_to_location(l:location_index)
    else
      break
    endif
  endfor

  redraw
endf

" TODO: don't extract?
fun! s:open_next_location_in_new_or_existing_tab() abort
  call s:log_debug('open_next_location_in_new_or_existing_tab 1')
  if empty(s:editor_data.locations)
    return
  endif
  call s:log_debug('open_next_location_in_new_or_existing_tab 2')

  let l:current_file = s:current_file()
  call s:log_debug('open_next_location_in_new_or_existing_tab 3')
  " TODO: &l:modified !=# 0 - is it correct here?
  if s:location_index >=# len(s:editor_data.locations) || &l:modified !=# 0 || (l:current_file !=# '' && !filereadable(l:current_file))
    return
  endif
  call s:log_debug('open_next_location_in_new_or_existing_tab 4')

  let l:initial_location_index = s:location_index

  call s:update_next_unique_location_index()
  call s:log_debug('open_next_location_in_new_or_existing_tab 5')

  if l:initial_location_index !=# s:location_index
    call s:log_debug('open_next_location_in_new_or_existing_tab 6')
    call s:jump_to_location(s:location_index)
  endif
  call s:log_debug('open_next_location_in_new_or_existing_tab 7')
endf

" TODO: don't extract?
fun! s:open_prev_location_in_new_or_existing_tab() abort
  call s:log_debug('open_prev_location_in_new_or_existing_tab 1')
  if empty(s:editor_data.locations)
    return
  endif

  let l:current_file = s:current_file()
  " TODO: &l:modified !=# 0 - is it correct here?
  if s:location_index <=# 0 || &l:modified !=# 0 || (l:current_file !=# '' && !filereadable(l:current_file))
    return
  endif

  let l:initial_location_index = s:location_index

  call s:update_prev_unique_location_index()

  if l:initial_location_index !=# s:location_index
    call s:log_debug('open_prev_location_in_new_or_existing_tab 2')
    call s:jump_to_location(s:location_index)
  endif
  call s:log_debug('open_prev_location_in_new_or_existing_tab 3')
endf

" TODO: naming? refactoring?
fun! s:update_next_unique_location_index() abort
  call s:log_debug('update_next_unique_location_index 1 localtion_index=' . s:location_index)
  " go to next unedited location with different path or line
  let l:location = s:current_location()
  while s:location_index <# len(s:editor_data.locations) - 1 && (s:is_same_location(l:location, s:current_location()) || s:is_edited_location(s:current_location()))
    let s:location_index += 1
  endwhile
  call s:log_debug('update_next_unique_location_index 2 localtion_index=' . s:location_index)

  " go to last unedited location on the same line
  while s:location_index <# len(s:editor_data.locations) - 1 && s:is_same_location(s:current_location(), s:next_location())
    let s:location_index += 1
  endwhile

  call s:log_debug('update_next_unique_location_index 3 localtion_index=' . s:location_index)
  while s:location_index <# len(s:editor_data.locations) - 1 && s:is_edited_location(s:current_location())
    let s:location_index += 1
  endwhile

  call s:log_debug('update_next_unique_location_index 4 localtion_index=' . s:location_index)
  while s:location_index <# len(s:editor_data.locations) - 1 && s:is_same_location(s:current_location(), s:next_location())
    let s:location_index += 1
  endwhile
  call s:log_debug('update_next_unique_location_index 5 localtion_index=' . s:location_index)
endf

" TODO: naming? remove? refactoring?
fun! s:update_prev_unique_location_index() abort
  let l:location = s:current_location()
  while s:location_index >=# 1 && (s:is_same_location(s:current_location(), l:location) || s:is_edited_location(s:current_location()))
    let s:location_index -= 1
  endwhile

  " go to first unedited location on the same line
  while s:location_index >=# 1 && s:is_same_location(s:current_location(), s:prev_location())
    let s:location_index -= 1
  endwhile

  while s:location_index >=# 1 && s:is_edited_location(s:current_location())
    let s:location_index -= 1
  endwhile

  while s:location_index >=# 1 && s:is_same_location(s:current_location(), s:prev_location())
    let s:location_index -= 1
  endwhile
endf

fun! s:on_buffer_write() abort
  let l:current_file = s:current_file()
  if l:current_file !=# '' && filereadable(l:current_file)
    let l:changes = s:update_locations(l:current_file)
    if l:changes ># 0
      call s:maybe_copy_to_temp(l:current_file)
      let s:editor_data.corrected_locations = v:true
      call g:CargoLimitUpdate(s:editor_data)
    endif
  endif
endf

fun! s:update_locations(path) abort
  "call s:log_info('update_locations ' . a:path . ' BEG locations = ' . json_encode(s:editor_data.locations))

  let [l:line_to_shift, l:edited_line_numbers] = s:compute_shifts_and_edits(a:path)

  let l:shift_accumulator = 0
  for l:index in range(0, len(l:line_to_shift) - 1)
    let l:shifted_lines = l:line_to_shift[l:index][1]
    let l:start = l:line_to_shift[l:index][0]
    let l:end = l:index + 1 <# len(l:line_to_shift) ? l:line_to_shift[l:index + 1][0] : v:null
    let l:shift_accumulator += l:shifted_lines
    let l:edited_line_numbers = s:shift_locations(a:path, l:edited_line_numbers, l:start, l:end, l:shift_accumulator)
  endfor

  call s:ignore_edited_lines_of_current_file(l:edited_line_numbers, a:path)
  return len(l:line_to_shift) + len(l:edited_line_numbers)
endf

fun! s:compute_shifts_and_edits(path) abort
  let l:temp_source_path = s:temp_source_path(a:path)

  const DIFF_STATS_PATTERN = '@@ '
  const DIFF_COMMAND =
    \ 'git diff --unified=0 --ignore-cr-at-eol --no-index --no-color --no-ext-diff -- '
    \ . fnameescape(l:temp_source_path)
    \ . ' '
    \ . a:path

  let l:line_to_shift = [] " TODO: naming
  let l:edited_line_numbers = {}
  if !filereadable(l:temp_source_path)
    return [l:line_to_shift, l:edited_line_numbers]
  endif

  let l:diff_stdout_lines = split(system(DIFF_COMMAND), "\n")
  let l:diff_stdout_line_number = 0 " TODO: rename to index?
  while l:diff_stdout_line_number <# len(l:diff_stdout_lines) - 1
    let l:diff_line = l:diff_stdout_lines[l:diff_stdout_line_number]
    if s:starts_with(l:diff_line, DIFF_STATS_PATTERN)
      let l:raw_diff_stats = split(split(l:diff_line, DIFF_STATS_PATTERN)[0], ' ')

      let [l:removal_offset, l:removals] = s:parse_diff_stats(l:raw_diff_stats[0], '-')
      let [l:addition_offset, l:additions] = s:parse_diff_stats(l:raw_diff_stats[1], '+')
      let l:shifted_lines = l:additions - l:removals

      call add(l:line_to_shift, [l:removal_offset, l:shifted_lines])
      let l:edited_line_numbers = s:update_edited_line_numbers(l:edited_line_numbers, l:removal_offset, l:removals, l:diff_stdout_lines, l:diff_stdout_line_number)
    endif
    let l:diff_stdout_line_number += 1
  endwhile

  return [l:line_to_shift, l:edited_line_numbers]
endf

fun! s:shift_locations(path, edited_line_numbers, start, end, shift_accumulator) abort
"  let l:wat_lines = []
"  for i in s:editor_data.locations
"    call add(l:wat_lines, i.line)
"  endfor
"  call s:log_info('BEG lines', l:wat_lines)

  for l:index in range(0, len(s:editor_data.locations) - 1)
    let l:current_location = s:editor_data.locations[l:index] " TODO: why current? naming
    if l:current_location.path ==# a:path
      let l:current_line = l:current_location.line
      if l:current_line ># a:start && (a:end ==# v:null || l:current_line <# a:end)
        let s:editor_data.locations[l:index].line += a:shift_accumulator
      endif
    endif
  endfor


"  let l:wat_lines = []
"  for i in s:editor_data.locations
"    call add(l:wat_lines, i.line)
"  endfor
"  call s:log_info('END lines', l:wat_lines)

  " TODO
  for l:line in keys(a:edited_line_numbers)
    if l:line ># a:start && (a:end ==# v:null || l:line <# a:end)
      call remove(a:edited_line_numbers, l:line)
      let a:edited_line_numbers[l:line + a:shift_accumulator] = v:true
    endif
  endfor

  return a:edited_line_numbers
endf

fun! s:parse_diff_stats(text, delimiter) abort
  let l:offset_and_lines = split(split(a:text, a:delimiter)[0], ',')
  let l:offset = str2nr(l:offset_and_lines[0])
  let l:lines = len(l:offset_and_lines) ># 1 ? str2nr(l:offset_and_lines[1]) : 1
  return [l:offset, l:lines]
endf

fun! s:update_edited_line_numbers(edited_line_numbers, removal_offset, removals, diff_stdout_lines, diff_stdout_line_number) abort
  for l:index in range(0, a:removals - 1)
    let l:next_diff_line = a:diff_stdout_lines[a:diff_stdout_line_number + l:index]
    let a:edited_line_numbers[a:removal_offset + l:index] = v:true
  endfor
  return a:edited_line_numbers
endf

" TODO: naming
fun! s:ignore_edited_lines_of_current_file(edited_line_numbers, current_file) abort
  for l:line in keys(a:edited_line_numbers)
    if !has_key(s:edited_locations, a:current_file)
      let s:edited_locations[a:current_file] = {}
    endif
    let s:edited_locations[a:current_file][l:line] = v:true
  endfor
endf

fun! s:is_edited_location(location) abort
  return has_key(s:edited_locations, a:location.path) && has_key(s:edited_locations[a:location.path], a:location.line)
endf

fun! s:is_same_location(first, second) abort
  return a:first.path ==# a:second.path && a:first.line ==# a:second.line
endf

fun! s:maybe_delete_dead_unix_socket(server_address) abort
  const LSOF_EXECUTABLE = 'lsof'
  const LSOF_COMMAND = LSOF_EXECUTABLE . ' -U'

  if !filereadable(a:server_address)
    return
  endif

  call system('which ' . LSOF_EXECUTABLE)
  let l:lsof_is_installed = v:shell_error ==# 0
  if !l:lsof_is_installed
    return
  endif

  let l:lsof_stdout = system(LSOF_COMMAND)
  let l:lsof_succeed = v:shell_error ==# 0
  if l:lsof_succeed
    let l:socket_is_dead = !s:contains_str(l:lsof_stdout, a:server_address)
    if l:socket_is_dead
      let l:ignore = luaeval('os.remove(_A)', a:server_address)
      call s:log_info('removed dead socket', a:server_address)
    endif
  else
    call s:log_error('failed to execute', LSOF_COMMAND)
  endif
endf

fun! s:recreate_temp_sources_dir() abort
  if s:temp_sources_dir !=# v:null
    call delete(s:temp_sources_dir, 'rf')
    call mkdir(s:temp_sources_dir, 'p', 0700)
  endif
endf

fun! s:temp_source_path(path) abort
  return s:temp_sources_dir . '/' . s:escape_path(a:path)
endf

fun! s:maybe_copy_to_temp(path) abort
  call s:maybe_copy(a:path, s:temp_source_path(a:path))
endf

fun! s:maybe_copy(source, destination) abort
  const MAX_SIZE_BYTES = 1024 * 1024
  if getfsize(a:source) <=# MAX_SIZE_BYTES
    let l:data = readblob(a:source)
    call writefile(l:data, a:destination, 'b')
  endif
endf

fun! s:current_file() abort
  return resolve(expand('%:p'))
endf

fun! s:escape_path(path) abort
  return substitute(a:path, '[/\\:]', '%', 'g')
endf

fun! s:starts_with(longer, shorter) abort
  return a:longer[0 : len(a:shorter) - 1] ==# a:shorter
endf

fun! s:contains_str(text, pattern) abort
  return stridx(a:text, a:pattern) !=# -1
endf

fun! s:jump_to_location(location_index) abort
  let l:location = s:editor_data.locations[a:location_index]
  execute 'tab drop ' . fnameescape(l:location.path)
  call cursor((l:location.line), (l:location.column))
endf

fun! s:current_location() abort
  return s:editor_data.locations[s:location_index]
endf

fun! s:next_location() abort
  return s:editor_data.locations[s:location_index + 1]
endf

fun! s:prev_location() abort
  return s:editor_data.locations[s:location_index - 1]
endf

fun! s:log_error(...) abort
  if g:CargoLimitVerbosity >=# 1
    echohl Error
    redraw
    echon s:log_str(a:000)
    echohl None
  endif
endf

fun! s:log_warn(...) abort
  if g:CargoLimitVerbosity >=# 2
    echohl WarningMsg
    echon s:log_str(a:000) . "\n"
  endif
endf

fun! s:log_info(...) abort
  if g:CargoLimitVerbosity >=# 3
    echohl None
    echon s:log_str(a:000)
  endif
endf

fun! s:log_debug(...) abort
  if g:CargoLimitVerbosity >=# 4
    echohl None
    echon s:log_str(a:000)
  endif
endf

fun! s:log_str(args)
  return '[cargo-limit] ' . join(a:args, ' ')
endf

fun! g:CargoLimitDebug()
  call s:log_info('editor_data ' . json_encode(s:editor_data) . "\nedited_locations=" . json_encode(s:edited_locations) . "\nlen(locations)=" . len(s:editor_data.locations) . "\nlocation_index=" . s:location_index . "\n&l:modified=" . &l:modified)
endfunction

fun! g:CargoLimitWorkspaceRoot() abort
  return fnameescape(s:workspace_root)
endf

call s:main()

" vim:shiftwidth=2 softtabstop=2 tabstop=2
