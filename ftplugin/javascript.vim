if exists('g:loaded_flow_plus')
    finish
endif

let g:loaded_flow_plus = 1
let g:flow#flowpath = 'flow'
let g:flow#flags = ' --from vim --json --no-auto-start'

function! s:FlowCoverageHide()
    for l:match in getmatches()
        if stridx(l:match['group'], 'FlowCoverage') == 0
            call matchdelete(l:match['id'])
        endif
    endfor

    let b:flow_highlights_drawn = 0
endfunction

function! GetLine(line)
    return [ get(a:line, 'line'), get(a:line, 'column') ]
endfunction

function! s:FlowCoverageRefresh()
    let l:isflow = getline(1)

    if l:isflow !~# '^\/[*/]\s*@flow'
        call s:FlowCoverageHide()
        return
    endif

    if !exists('b:flow_coverage_highlight_enabled')
        let b:flow_coverage_highlight_enabled = 1
    endif

    let l:command = g:flow#flowpath . ' coverage ' .
                \ g:flow#flags . ' ' . expand('%:p')
    let l:result = system(l:command)

    if v:shell_error > 0 || empty(l:result)
        let b:flow_coverage_status = ''
        return
    endif

    let l:json_result = json_decode(l:result)
    let l:expressions = get(l:json_result, 'expressions')
    let l:covered = get(l:expressions, 'covered_count')
    let l:total = l:covered + get(l:expressions, 'uncovered_count')
    let l:percent = l:total > 0 ?
                \ ((l:covered / str2float(l:total)) * 100.0) :
                \ 0.0

    let b:flow_coverage_status = printf(
                \   '%.2f%% (%d/%d)',
                \   l:percent,
                \   l:covered,
                \   l:total
                \)

    let b:flow_coverage_uncovered_locs = get(l:expressions, 'uncovered_locs')

    if b:flow_coverage_highlight_enabled
        call s:FlowCoverageShowHighlights()
    endif
endfunction

function! s:FlowCoverageShowHighlights()
    if !exists('b:flow_coverage_uncovered_locs')
        call s:FlowCoverageRefresh()
    endif

    call s:FlowCoverageHide()

    for l:line in b:flow_coverage_uncovered_locs
        let [l:line_start, l:col_start] = GetLine(get(l:line, 'start'))
        let [l:line_end, l:col_end] = GetLine(get(l:line, 'end'))

        if l:line_start == l:line_end
            let l:positions = [[
                        \   l:line_start,
                        \   l:col_start,
                        \   l:col_end - l:col_start + 1
                        \ ]]
        else
            let l:positions = []
            for l:each_line in range(l:line_start, l:line_end)
                if l:each_line == l:line_start
                    let l:each_pos = [l:each_line, l:col_start, 100]
                elseif l:each_line == l:line_end
                    let l:each_pos = [l:each_line, 1, l:col_end]
                else
                    let l:each_pos = l:each_line
                endif

                call add(l:positions, l:each_pos)
            endfor
        endif

        call matchaddpos('FlowCoverage', l:positions)
    endfor
    let b:flow_highlights_drawn = 1
endfunction

function! s:ToggleHighlight()
    if !exists('b:flow_highlights_drawn')
        return
    endif
    if b:flow_highlights_drawn && b:flow_coverage_highlight_enabled
        let b:flow_coverage_highlight_enabled = 0
        call s:FlowCoverageHide()
    else
        let b:flow_coverage_highlight_enabled = 1
        call s:FlowCoverageShowHighlights()
    endif
endfunction

function! s:FindRefs(pos) abort
    if exists('b:flow_current_refs')
        unlet b:flow_current_refs
    endif

    let l:command = g:flow#flowpath . ' find-refs ' . a:pos . g:flow#flags
    let l:result = system(l:command, getline(1, '$'))

    if v:shell_error > 0 || empty(l:result)
        if v:shell_error == 6
            echom 'Flow: Server not running'
        endif
        return
    endif

    let b:flow_current_refs = json_decode(l:result)
endfunction

function! s:NextRef(delta) abort
    let l:pos = line('.') . ' ' . col('.')

    if !exists('b:flow_refs_last_jump') || l:pos != b:flow_refs_last_jump ||
                \ !exists('b:flow_current_refs')
        call s:FindRefs(l:pos)
        if !exists('b:flow_current_refs')
            return
        endif
    endif

    let l:refs_len = len(b:flow_current_refs)
    if l:refs_len == 0
        echom 'Flow: Current position is not a reference'
        return
    endif

    let l:offset = line2byte(line('.')) + col('.') - 2
    let l:idx = Search(l:offset, b:flow_current_refs)

    if l:idx > -1
        let l:next_ref_idx = l:idx + (a:delta)
        if l:next_ref_idx < 0 || l:next_ref_idx >= l:refs_len
            let l:next_ref_idx = float2nr(fmod(l:next_ref_idx, l:refs_len))
        endif

        let l:next_ref = get(b:flow_current_refs, l:next_ref_idx)
        let l:next_ref_start = get(l:next_ref, 'start')
        let [l:line, l:column] = GetLine(l:next_ref_start)

        " Save last jump to reuse the refs
        let b:flow_refs_last_jump = l:line . ' ' . l:column
        call cursor(l:line, l:column)
    else
        echom 'Flow: No references found'
    endif
endfunction

function! Search(value, list)
    let l:min_index = 0
    let l:max_index = len(a:list) - 1

    while l:min_index <= l:max_index
        let l:curr_index = float2nr((l:min_index + l:max_index) / 2)
        let l:curr_el = get(a:list, l:curr_index)
        let l:offset_start = get(l:curr_el['start'], 'offset')
        let l:offset_end = get(l:curr_el['end'], 'offset')

        if l:offset_start <= a:value && l:offset_end >= a:value
            return l:curr_index
        elseif l:offset_start < a:value
            let l:min_index = l:curr_index + 1
        else
            let l:max_index = l:curr_index - 1
        endif
    endwhile

    return -1
endfunction

function! s:TypeAtPos()
    let l:pos = line('.') . ' ' . col('.')
    let l:command = g:flow#flowpath . ' type-at-pos ' . l:pos . g:flow#flags
    let l:result = system(l:command, getline(1, '$'))

    if v:shell_error > 0 || empty(l:result)
        return
    endif

    let l:json_result = json_decode(l:result)
    echo l:json_result['type']
endfunction

function! s:GetDefAtPos()
    let l:pos = line('.') . ' ' . col('.')
    let l:command = g:flow#flowpath . ' get-def ' . l:pos . g:flow#flags
    let l:result = system(l:command, getline(1, '$'))

    if v:shell_error > 0 || empty(l:result)
        return
    endif

    let l:def = json_decode(l:result)
    let l:path = l:def['path']
    if empty(l:path)
        echom 'Flow: No definition found'
    elseif l:path =~# '-$'
        call cursor(l:def['line'], l:def['start'])
    elseif filereadable(l:path)
        execute 'edit' l:path
        call cursor(l:def['line'], l:def['start'])
    endif
endfunction

command! FlowCoverageToggle call s:ToggleHighlight()
command! FlowNextRef call s:NextRef(1)
command! FlowPrevRef call s:NextRef(-1)
command! FlowTypeAtPos call s:TypeAtPos()
command! FlowGetDef call s:GetDefAtPos()

highlight def link FlowCoverage SpellCap

augroup FlowCoverage
autocmd!
autocmd BufLeave * call s:FlowCoverageHide()
autocmd BufWritePost,BufReadPost,BufEnter * call s:FlowCoverageRefresh()
augroup END
