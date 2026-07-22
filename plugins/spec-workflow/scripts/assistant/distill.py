"""Distiller subsystem contract (SPEC-ASSISTANT.md §5a, E3).

Stub only -- a later E3 task fills this in with the real distillation loop
that the `distiller` worker (see engine.py's WORKER_NAMES) will run instead
of its v1 heartbeat no-op. AST-010 creates this module only so the worker
registry has a name to import against later -- no distiller logic lands here
yet.

AST-018 adds one seam ahead of that loop: `refresh_after_mint`, below.
"""


def refresh_after_mint(identities, root, role="assistant"):
    """SPEC-ASSISTANT.md §9.3 seam: "WHEN the distiller mints THE SYSTEM
    SHALL refresh the embeddings index so new notes are recallable within
    one batch cycle." AST-018 delivers this hook only -- the batching
    worker loop that calls it on the distiller's own mint cadence is E3's
    own task (this module otherwise stays a stub until then). Thin wrapper
    over brain.refresh_index, imported lazily (inside the function, not at
    module top) so importing distill.py alone never imports brain.py --
    same lazy-import discipline turns.make_default_recall uses for the
    same reason (Sec17.1: isolation extends to import time).

    `root` is accepted (unused by refresh_index itself) to keep this
    seam's signature consistent with the rest of the assistant subsystem's
    identities/root/role calling convention (e.g. turns.make_default_recall)
    -- E3's real worker loop may need root for its own bookkeeping around
    this call.
    """
    import brain as brain_module

    return brain_module.refresh_index(identities, role)
