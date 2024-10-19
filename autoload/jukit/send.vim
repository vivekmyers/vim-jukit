fun! s:clean_outhist_time_passed() abort
    if !exists("b:last_output_checked")
        let b:last_output_checked = localtime()
    endif

    if localtime() > (b:last_output_checked + g:jukit_clean_outhist_freq)
        let b:last_output_checked = localtime()
        return 1
    endif
    return 0
endfun

fun! s:clean_outhist_autocmd() abort
    if exists('#jukit_clean_outhist') && g:jukit_clean_outhist_freq >= 0
        return
    endif

    augroup jukit_clean_outhist
        autocmd CursorHold <buffer> call jukit#send#clean_output_history()
    augroup END
endfun

fun! jukit#send#clean_output_history(...) abort
    if !s:clean_outhist_time_passed() && !a:0
        return
    endif

    let ids = jukit#util#get_all_ids()
    if len(ids[1])
        let all_ids = [ids[1][0]] + ids[2]
    else
        let all_ids = []
    endif
python3 << EOF
import vim, os, sys
sys.path.append(vim.eval('jukit#util#plugin_path() . "/helpers"'))
from ipynb_convert import util

current_ids = vim.eval('all_ids')

fname = vim.eval("expand('%:p')")
dir_, f = os.path.split(fname)
outhist_file = os.path.join(dir_, '.jukit', f'{os.path.splitext(f)[0]}_outhist.json')

util.clear_obsolete_output(current_ids, outhist_file)
EOF
endfun

fun! s:output_exists() abort
    if !jukit#splits#split_exists('output')
        echom "[vim-jukit] No split window found"
        return 0
    endif
    return 1
endfun

fun! s:send(bufnr, text) abort
    if g:jukit_terminal == 'kitty'
        call jukit#kitty#cmd#send_text(g:jukit_output_title, a:text)
    elseif g:jukit_terminal == 'vimterm'
        if g:_jukit_is_windows
            call term_sendkeys(a:bufnr, a:text)
            exec "sleep " . g:_jukit_send_delay
            call term_sendkeys(a:bufnr, "\r")
        else
            call term_sendkeys(a:bufnr, a:text . "\r")
        endif
    elseif g:jukit_terminal == 'nvimterm'
        if g:_jukit_is_windows
            call chansend(a:bufnr, a:text)
            exec "sleep " . g:_jukit_send_delay
            call chansend(a:bufnr, "\r")
        else
            call chansend(a:bufnr, a:text . "\r")
        endif
        exe bufwinnr(g:jukit_output_buf) . 'wincmd w'
        call feedkeys("G:wincmd p\<cr>", "nxt")
    elseif g:jukit_terminal == 'tmux'
        call jukit#tmux#cmd#send_text(g:jukit_output_title, a:text)
    else
        echom '[vim-jukit] Terminal `' . g:jukit_terminal . '` not supported'
    endif
endfun

fun! s:send_to_split(magic_cmd, code, save, ...) abort
    if g:_jukit_python && g:jukit_ipython
        let param = g:jukit_ipy_opts
        if !a:0 && a:save
            let param = param . ' -s'
        elseif a:0
            let param = a:1
        endif

        if g:jukit_show_prompt
            let param = param . ' -p'
        endif

        call jukit#util#ipython_info_write({'cmd_opts': param, 'cmd': a:code})
        call s:send(g:jukit_output_title, a:magic_cmd)
    else
        call s:send(g:jukit_output_title, a:code)
    endif
endfun

fun! jukit#send#send_to_split(code) abort
    call s:send_to_split('%jukit_run', a:code, 0)
endfun

fun! jukit#send#line() abort
    " Sends a single line to split-window/ipython shell

    if !s:output_exists()
        return
    endif

    let cmd_count = v:count == 0 ? 1 : v:count
    let code = join(getline(line('.'), line('.')+cmd_count-1), "\n")
    call s:send_to_split('%jukit_run', code, 0)
    call cursor(line('.')+cmd_count, 1)
endfun

fun! jukit#send#selection() abort
    " Sends visually selected text to split-window/ipython shell
    
    if !s:output_exists()
        return
    endif
   
    if !jukit#splits#split_exists('output')
        echo "No split window found"
        return
    endif

    let selection = jukit#util#get_visual_selection()
    if g:jukit_save_output && match(selection, '|%%--%%|') > -1
        let md_start = escape(jukit#util#get_lang_info()[0], '"')
        let param = g:jukit_ipy_opts . ' -s' . ' --md_cell_start=' . md_start
        call s:send_to_split('%jukit_run_split', selection, 1, param)
    else
        call s:send_to_split('%jukit_run', selection, 0)
    endif
endfun

fun! jukit#send#section(move_next) abort
    " Sends code of the current section to split-window/ipython shell
    
    call jukit#util#md_buffer_vars()
    if !s:output_exists()
        return
    endif
   
    let cmd_count = v:count == 0 ? 1 : v:count
    if cmd_count == 1
        call s:send_single_section(a:move_next)
    else
        call s:send_multiple_sections(count)
    endif
endfun

fun! s:send_single_section(move_next) abort
    let pos1 = search('|%%--%%|', 'nbW') + 1
    let pos2 = search('|%%--%%|', 'nW')

    if pos2 != 0
        let pos2 -= 1
    else
        let pos2 = line('$')
    endif

    let code = join(getline(pos1, pos2), "\n")

    let cell_id = jukit#util#get_current_cell_id()
    let md_cur = jukit#util#is_md_cell(cell_id)
    let param = g:jukit_ipy_opts . ' --cell_id=' . cell_id
    if g:jukit_save_output && !md_cur
        let param = param . ' -s'
        if &ft =~ 'python'
            call s:clean_outhist_autocmd()
        endif
    endif
    call s:send_to_split('%jukit_run', code, g:jukit_save_output, param)

    if a:move_next
        let next_cell_pos = search('|%%--%%|', 'W')
        if next_cell_pos != 0
            call cursor(line('.')+1, 1)
        else
            call cursor(line('$'), 1)
        endif
    endif
endfun

fun! s:send_multiple_sections(count) abort
    let pos1 = search('|%%--%%|', 'nbW') + 1
    for i in range(a:count)
        let pos2 = search('|%%--%%|', 'nW')

        if pos2 != 0
            let pos2 -= 1
        elseif pos2 == 0
            let pos2 = line('$')
            break
        endif

        let next_cell_pos = search('|%%--%%|', 'W')
        if next_cell_pos != 0
            call cursor(line('.')+1, 1)
        else
            call cursor(line('$'), 1)
        endif
    endfor

    let code = join(getline(pos1, pos2), "\n")

    call s:send_to_split('%jukit_run_split', code, g:jukit_save_output)
endfun

fun! jukit#send#until_current_section() abort
    " Sends code from the beginning until (and including) the current section
    " to split-window/ipython shell

    if !s:output_exists()
        return
    endif


    let ids_above = jukit#util#get_marker_above()
    if !ids_above['pos']
        call jukit#send#section(0)
        return
    endif

    let pos1 = 1
    let pos2 = search('|%%--%%|', 'nW')

    if pos2 != 0
        let pos2 -= 1
    else
        let pos2 = line('$')
    endif

    let code = join(getline(pos1, pos2), "\n")

    if g:jukit_save_output
        let md_start = escape(jukit#util#get_lang_info()[0], '"')
        let param = g:jukit_ipy_opts . ' -s' . ' --md_cell_start=' . md_start
        call s:send_to_split('%jukit_run_split', code, 1, param)
    else
        call s:send_to_split('%jukit_run_split', code, 0)
    endif
endfun

fun! jukit#send#all() abort
    " Sends all code in file to window
    
    if !s:output_exists()
        return
    endif

    let cell_id = jukit#util#get_current_cell_id()
    if cell_id == 'NONE'
        call jukit#send#section(0)
        return
    endif

    let code = join(getline(1, '$'), "\n")

    if g:jukit_save_output
        let md_start = escape(jukit#util#get_lang_info()[0], '"')
        let param = g:jukit_ipy_opts . ' -s' . ' --md_cell_start=' . md_start
        call s:send_to_split('%jukit_run_split', code, 1, param)
    else
        call s:send_to_split('%jukit_run_split', code, 0)
    endif
endfun
