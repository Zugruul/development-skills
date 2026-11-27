"""#560 over-WIP moves and #563 separate In progress / In review limits.

Real board.sh / next.py entrypoints against a stubbed gh; no network.
"""
import json
import unittest
import test_checkpoint as fixture

SCRIPTS = fixture.SCRIPTS


class OverWipTests(unittest.TestCase):
    save = fixture.CheckpointTests.save
    run_cmd = fixture.CheckpointTests.run_cmd
    board = fixture.CheckpointTests.board
    picker = fixture.CheckpointTests.picker

    def setUp(self):
        fixture.CheckpointTests.setUp(self)
        gh = self.root / 'bin' / 'gh'
        gh.write_text(gh.read_text().replace(
            '  *) echo "unexpected',
            '  "api -X") for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "$CALLS.body";; esac; done; echo "{}" ;;\n  *) echo "unexpected'))
        gh.write_text(gh.read_text().replace(
            'case "$1 $2" in',
            'case "$1 $2" in\n  "api graphql") [ -e "$CALLS.ratelimit" ] && { echo "API rate limit exceeded" >&2; exit 1; } ; exec python3 "$GH_GQL_ADAPTER" "$0" "$@" ;;', 1))
        self.body = self.root / 'calls.body'
        self.record = self.root / '.claude/over-wip.json'
        self.ratelimit = self.root / 'calls.ratelimit'

    def state(self, statuses, numbers=None):
        numbers = numbers or [239 + i for i in range(len(statuses))]
        self.items.write_text(json.dumps({'items': [dict(id=f'ITEM{n}', status=s, content={'number': n})
                                                   for s, n in zip(statuses, numbers)]}))
        for n in numbers:
            (self.root / '.claude/board-comments-seen.json').write_text(json.dumps({str(k): True for k in numbers}))

    def settings(self, limit=1, serial=False, **extra):
        self.cfg['methodology'].update(maxInProgress=limit, serialDelivery=serial, **extra)
        self.save()

    def lines(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def reset(self):
        for p in (self.calls, self.body, self.record, self.telemetry, self.queue):
            p.unlink(missing_ok=True)

    # --- #560 acceptance 1 and 2 -------------------------------------------------
    def test_without_flag_at_limit_is_still_refused(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('capacity 1/1 occupied', result.stdout)
        self.assertNotIn('item-edit', self.calls.read_text())
        self.assertFalse(self.record.exists())

    def test_flag_at_limit_moves_comments_once_and_records(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress', '--over-wip', 'human asked for SC-147',
                            '--over-wip-by', 'alice')
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.lines()
        self.assertEqual(sum('project item-edit' in c for c in calls), 1, calls)
        self.assertEqual(sum(c.startswith('api -X POST repos/') and '/issues/239/comments -F body=@' in c for c in calls), 1, calls)
        body = self.body.read_text()
        self.assertIn('human asked for SC-147', body)
        self.assertIn('alice', body)
        record = json.loads(self.record.read_text())
        self.assertEqual(record['main#239']['reason'], 'human asked for SC-147')
        self.assertEqual(record['main#239']['by'], 'alice')

    def test_default_requester_is_orchestrator(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress', '--over-wip', 'why')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('orchestrator', self.body.read_text())
        self.assertEqual(json.loads(self.record.read_text())['main#239']['by'], 'orchestrator')

    def test_over_wip_path_costs_exactly_one_extra_call(self):
        self.settings(2)
        self.state(['Backlog', 'In progress'])
        base = self.board('move', '239', 'In progress')
        self.assertEqual(base.returncode, 0, base.stdout)
        baseline = self.lines()
        self.reset()
        self.state(['Backlog', 'In progress', 'In progress'])
        (self.root / '.claude/board-cache.json').write_text('{"239":{"itemId":"ITEM239","status":"Backlog"}}')
        result = self.board('move', '239', 'In progress', '--over-wip', 'why')
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.lines()
        self.assertEqual(len(calls), len(baseline) + 1, (baseline, calls))
        self.assertEqual(sum(c.startswith('api -X POST repos/') and '/issues/239/comments -F body=@' in c for c in calls), 1)
        self.assertNotIn('issue comment', '\n'.join(calls))
        self.assertEqual(sum('graphql' in c or 'item-list' in c for c in calls),
                         sum('graphql' in c or 'item-list' in c for c in baseline))

    def test_failed_comment_warns_and_keeps_the_move(self):
        gh = self.root / 'bin' / 'gh'
        gh.write_text(gh.read_text().replace('"api -X") ', '"api -X") echo "HTTP 403 rate limit" >&2; exit 1 ;; "x x") '))
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress', '--over-wip', 'why')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('WARN: could not post the over-WIP comment', result.stdout)
        self.assertIn('project item-edit', self.calls.read_text())
        self.assertIn('main#239', json.loads(self.record.read_text()))

    def test_flag_under_limit_is_a_plain_move(self):
        self.settings(2)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress', '--over-wip', 'why')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('/comments', self.calls.read_text())
        self.assertFalse(self.record.exists())
        self.assertFalse(self.body.exists())

    def test_flag_needs_a_reason(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress', '--over-wip')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('--over-wip', result.stdout)
        self.assertEqual(self.lines(), [])

    # --- acceptance 3 -------------------------------------------------------------
    def test_next_lists_overage_and_refuses_new_work(self):
        self.settings(1)
        self.state(['In progress', 'In progress', 'Backlog'], [239, 240, 241])
        self.record.write_text(json.dumps({'main#239': {'reason': 'human asked', 'by': 'orchestrator', 'status': 'In progress'}}))
        out = self.picker().stdout
        self.assertIn('OVER WIP 2/1: #239 (human asked)', out)
        self.assertNotIn('PICK:', out)
        self.assertIn('RESUME:', out)
        self.assertTrue(self.record.exists())

    def test_next_clears_stale_records(self):
        self.settings(2)
        # #239 left In progress; #240 is still In progress but the count is back under the limit.
        self.state(['Deployed', 'In progress'], [239, 240])
        self.record.write_text(json.dumps({
            'main#239': {'reason': 'gone', 'by': 'x', 'status': 'In progress'},
            'main#240': {'reason': 'back under', 'by': 'x', 'status': 'In progress'}}))
        out = self.picker().stdout
        self.assertNotIn('OVER WIP', out)
        self.assertEqual(json.loads(self.record.read_text()), {})

    def test_board_next_prints_overage(self):
        self.settings(1)
        self.state(['In progress', 'In progress'], [239, 240])
        self.record.write_text(json.dumps({'main#240': {'reason': 'lane', 'by': 'orchestrator', 'status': 'In progress'}}))
        result = self.board('next')
        self.assertIn('OVER WIP 2/1: #240 (lane)', result.stdout)
        self.assertNotIn('PICK:', result.stdout)

    # --- #563 separate limits -----------------------------------------------------
    def test_split_limits_review_full_does_not_block_in_progress(self):
        self.settings(1, wipLimits={'inProgress': 2, 'inReview': 1})
        self.state(['Backlog', 'In progress', 'In review'])
        result = self.board('move', '239', 'In progress')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_split_limits_each_status_has_its_own_limit(self):
        board = self.cfg['boards'][0]
        board['statusFlow'][2] = 'Reviewing'  # dodges the gate preflight, like test_wip_admission
        board['fields']['status']['options']['Reviewing'] = 'review-option'
        self.settings(1, wipLimits={'inProgress': 1, 'inReview': 2})
        self.state(['Backlog', 'In progress'])
        self.assertNotEqual(self.board('move', '239', 'In progress').returncode, 0)
        self.reset()
        self.state(['In progress', 'Reviewing'])
        self.assertEqual(self.board('move', '239', 'Reviewing').returncode, 0)
        self.reset()
        self.state(['Backlog', 'Reviewing', 'Reviewing'])
        self.assertNotEqual(self.board('move', '239', 'Reviewing').returncode, 0)

    def test_absent_wip_limits_keeps_shared_limit(self):
        self.settings(1, serial=True)
        self.state(['Backlog', 'In review'])
        self.assertNotEqual(self.board('move', '239', 'In progress').returncode, 0)

    def test_next_shows_both_limits(self):
        self.settings(1, wipLimits={'inProgress': 2, 'inReview': 2})
        self.state(['In progress', 'In review', 'Backlog'], [239, 240, 241])
        out = self.picker().stdout
        self.assertIn('In progress 1/2', out)
        self.assertIn('In review 1/2', out)
        self.assertIn('PICK: #241', out)

    def test_next_split_warns_but_still_hands_out_work_when_review_pool_is_full(self):
        self.settings(1, wipLimits={'inProgress': 2, 'inReview': 1})
        for statuses, numbers in ((['In progress', 'In review', 'Backlog'], [239, 240, 241]),
                                  (['In review', 'Backlog'], [240, 241])):
            self.state(statuses, numbers)
            out = self.picker().stdout
            self.assertIn('PICK: #241', out)
            self.assertIn('WARN: In review 1/1 is at its limit', out)

    def test_next_split_refuses_new_work_when_progress_pool_is_full(self):
        self.settings(1, wipLimits={'inProgress': 1, 'inReview': 3})
        self.state(['In progress', 'Backlog'], [239, 241])
        out = self.picker().stdout
        self.assertNotIn('PICK:', out)
        self.assertIn('RESUME: #239', out)

    # --- review round 1 ------------------------------------------------------------
    def use_reviewing(self):
        board = self.cfg['boards'][0]
        board['statusFlow'][2] = 'Reviewing'
        board['fields']['status']['options']['Reviewing'] = 'review-option'

    def test_moves_between_counted_statuses_are_never_refused(self):
        self.use_reviewing()
        self.settings(1, wipLimits={'inProgress': 1, 'inReview': 1})
        self.state(['In progress', 'Reviewing'], [239, 240])
        self.assertEqual(self.board('move', '239', 'Reviewing').returncode, 0)
        self.reset()
        self.state(['Reviewing', 'In progress'], [239, 240])
        self.assertEqual(self.board('move', '239', 'In progress').returncode, 0)

    def test_pin_empty_array_expansion_form_in_source(self):
        src = (SCRIPTS / 'board-queue.sh').read_text()
        self.assertIn('${over_flag[@]+"${over_flag[@]}"}', src)

    def test_rate_limited_over_wip_move_queues_the_flag_and_replays_it(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        self.ratelimit.touch()
        result = self.board('move', '239', 'In progress', '--over-wip', 'human asked', '--over-wip-by', 'alice')
        self.assertEqual(result.returncode, 0, result.stdout)
        entry = json.loads(self.queue.read_text().splitlines()[-1])
        self.assertEqual((entry['op'], entry['over_wip'], entry['over_wip_by']), ('move', 'human asked', 'alice'))
        self.assertFalse(self.record.exists())
        self.ratelimit.unlink()
        self.reset_calls()
        result = self.board('flush')
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.lines()
        self.assertEqual(sum('project item-edit' in c for c in calls), 1, calls)
        self.assertEqual(sum('/issues/239/comments' in c for c in calls), 1, calls)
        self.assertIn('alice', self.body.read_text())
        self.assertIn('main#239', json.loads(self.record.read_text()))

    def test_mixed_flush_queue_over_wip_entry_does_not_leak_into_the_next_entry(self):
        # In-loop reset: entry A sets the flag; plain entry B (still at the limit) must be refused.
        self.settings(1)
        self.state(['Backlog', 'Backlog', 'In progress'], [239, 240, 241])
        (self.root / '.claude/board-comments-seen.json').write_text(json.dumps({'239': True, '240': True}))
        self.queue.write_text(
            json.dumps({'op': 'move', 'issue': '239', 'status': 'In progress', 'over_wip': 'lane A', 'over_wip_by': 'alice', 'ts': '2026-01-01T00:00:00Z'}) + '\n'
            + json.dumps({'op': 'move', 'issue': '240', 'status': 'In progress', 'ts': '2026-01-01T00:00:01Z'}) + '\n')
        self.board('flush')
        calls = self.lines()
        self.assertEqual(sum('project item-edit' in c for c in calls), 1, calls)
        self.assertEqual(sum('/issues/239/comments' in c for c in calls), 1, calls)
        self.assertEqual(sum('/comments' in c for c in calls), 1, calls)
        self.assertEqual(set(json.loads(self.record.read_text())), {'main#239'})
        self.assertIn('"issue": "240"', self.queue.read_text())

    def test_inherited_env_never_turns_a_queued_plain_move_into_an_over_wip_one(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        self.queue.write_text(json.dumps({'op': 'move', 'issue': '239', 'status': 'In progress', 'ts': '2026-01-01T00:00:00Z'}) + '\n')
        self.env.update(OVER_WIP_REASON='leaked', OVER_WIP_BY='mallory')
        self.board('flush')
        self.assertNotIn('project item-edit', self.calls.read_text() if self.calls.exists() else '')
        self.assertFalse(self.record.exists())
        self.assertFalse(self.body.exists())

    def test_flag_arguments_in_any_order_and_usage_errors(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        result = self.board('move', '239', 'In progress', '--over-wip-by', 'bob', '--over-wip', 'why')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(self.record.read_text())['main#239']['by'], 'bob')
        for args in (('--over-wip', 'why', '--over-wip-by'), ('--over-wip-by', 'bob'), ('--over-wip-by', ''),
                     ('--bogus',)):
            with self.subTest(args=args):
                self.reset()
                self.state(['Backlog', 'In progress'])
                result = self.board('move', '239', 'In progress', *args)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('unknown option' if args == ('--bogus',) else '--over-wip', result.stdout)
                self.assertEqual(self.lines(), [])

    def test_invalid_reasons_are_usage_errors_with_no_gh_call(self):
        self.settings(1)
        for args in (('--over-wip', '   '), ('--over-wip', '--over-wip-by', 'bob'), ('--over-wip', '--oops'),
                     ('--over-wip', 'why', '--over-wip-by', '--over-wip'), ('--over-wip', '\n \t')):
            with self.subTest(args=args):
                self.reset()
                self.state(['Backlog', 'In progress'])
                result = self.board('move', '239', 'In progress', *args)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn('--over-wip', result.stdout)
                self.assertEqual(self.lines(), [])

    def test_over_wip_and_accepted_by_user_cannot_be_combined_in_either_order(self):
        self.settings(1)
        for args in (('--accepted-by-user', 'ok', '--over-wip', 'why'),
                     ('--over-wip', 'why', '--accepted-by-user=ok'),
                     ('--over-wip', 'why', '--over-wip-by', 'bob', '--accepted-by-user', 'ok')):
            with self.subTest(args=args):
                self.reset()
                self.state(['Backlog', 'In progress'])
                result = self.board('move', '239', 'QA', *args)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn('cannot be combined', result.stdout)
                self.assertEqual(self.lines(), [])
        result = self.board('move', '239', '--over-wip', 'why', 'QA')
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('after STATUS', result.stdout)

    def test_unknown_option_and_missing_quote_keep_562_usage_errors(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        for args, needle in ((('--bogus', 'x'), '--accepted-by-user'), (('--accepted-by-user',), 'needs a quote')):
            result = self.board('move', '239', 'QA', *args)
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn(needle, result.stdout)
        self.assertEqual(self.lines(), [])

    def test_replay_ignores_an_invalid_queued_reason(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        self.queue.write_text(json.dumps({'op': 'move', 'issue': '239', 'status': 'In progress', 'over_wip': '--bogus', 'ts': '2026-01-01T00:00:00Z'}) + '\n')
        self.board('flush')
        self.assertNotIn('project item-edit', self.calls.read_text() if self.calls.exists() else '')
        self.assertFalse(self.record.exists())

    def test_reason_with_quotes_and_newlines_reaches_the_comment_body(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        reason = 'he said "go" and it\'s $HOME `x`\nsecond line'
        result = self.board('move', '239', 'In progress', '--over-wip', reason)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, self.body.read_text())
        self.assertEqual(json.loads(self.record.read_text())['main#239']['reason'], reason)

    def reset_calls(self):
        for p in (self.calls, self.body):
            p.unlink(missing_ok=True)

    # overage record pruning and file safety
    def old(self, **extra):
        return dict(reason='r', by='x', status='In progress', ts='2020-01-01T00:00:00Z', **extra)

    def test_records_of_other_boards_and_unseen_items_are_kept(self):
        self.settings(2)
        self.state(['In progress'], [240])
        self.record.write_text(json.dumps({'other#239': self.old(), 'main#777': self.old()}))
        self.picker()
        self.assertEqual(set(json.loads(self.record.read_text())), {'other#239', 'main#777'})

    def test_fresh_records_survive_pruning_and_old_seen_ones_do_not(self):
        import datetime
        now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.settings(5)
        self.state(['In progress', 'In progress'], [239, 240])
        self.record.write_text(json.dumps({'main#239': dict(self.old(), ts=now), 'main#240': self.old()}))
        out = self.picker().stdout
        self.assertNotIn('OVER WIP', out)
        self.assertEqual(set(json.loads(self.record.read_text())), {'main#239'})

    def test_seen_in_a_non_counted_status_drops_the_record(self):
        self.settings(1)
        self.state(['Deployed', 'In progress'], [239, 240])
        self.record.write_text(json.dumps({'main#239': self.old()}))
        self.picker()
        self.assertEqual(json.loads(self.record.read_text()), {})

    def test_corrupt_record_file_is_moved_aside_with_a_warning(self):
        self.settings(1)
        self.state(['Backlog', 'In progress'])
        self.record.write_text('{not json')
        result = self.board('move', '239', 'In progress', '--over-wip', 'why')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('corrupt', result.stdout)
        aside = list((self.root / '.claude').glob('over-wip.json.corrupt-*'))
        self.assertEqual(len(aside), 1)
        self.assertEqual(aside[0].read_text(), '{not json')
        self.assertIn('main#239', json.loads(self.record.read_text()))
        self.assertEqual(list((self.root / '.claude').glob('over-wip.json.tmp*')), [])

    def test_unlocked_reader_warns_and_moves_nothing_for_a_corrupt_file(self):
        self.settings(1)
        self.state(['In progress'], [239])
        self.record.write_text('{not json')
        result = self.picker()
        self.assertIn('corrupt', result.stdout)
        self.assertEqual(self.record.read_text(), '{not json')
        self.assertEqual(list((self.root / '.claude').glob('over-wip.json.corrupt-*')), [])

    def test_split_line_shows_only_counted_pools_and_never_none(self):
        self.settings(1, wipLimits={'inProgress': 2})
        self.state(['In progress', 'Backlog'], [239, 241])
        out = self.picker().stdout
        self.assertIn('WIP: In progress 1/2', out)
        self.assertNotIn('In review', out)
        self.assertNotIn('None', out)
        self.cfg['boards'][0]['statusFlow'] = ['Backlog', 'In progress']
        self.save()
        self.assertNotIn('None', self.picker().stdout)

    def test_empty_wip_limits_is_refused_by_admission(self):
        self.settings(1, wipLimits={})
        self.state(['Backlog'])
        result = self.board('move', '239', 'In progress')
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == '__main__':
    unittest.main()
