-- Conversation soft delete (W7). Source: phase-w7-conversation-deletion.md.
-- NULL = live; an ISO timestamp = deleted. The row stays as a tombstone so
-- decisions.conversation_id keeps a valid foreign key.
ALTER TABLE conversations ADD COLUMN deleted_at TEXT;
