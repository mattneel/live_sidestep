//! AppKit owns editing. This state only arbitrates application acknowledgements
//! against the full values observed from its field editor.

#[derive(Debug)]
struct Deferred {
    value: String,
    revision: u64,
}

#[derive(Debug)]
pub struct TextState {
    pub value: String,
    pub revision: u64,
    pub acknowledged: u64,
    composing: bool,
    deferred: Option<Deferred>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Observation {
    pub changed: bool,
    pub replace: bool,
}

impl TextState {
    pub fn new(value: String, revision: u64) -> Self {
        Self {
            value,
            revision,
            acknowledged: revision,
            composing: false,
            deferred: None,
        }
    }

    pub fn composing(&self) -> bool {
        self.composing
    }

    /// An observation is made before every incoming command, as well as from
    /// immediate native delegate callbacks. An equal observation is not an edit.
    pub fn observe(&mut self, value: &str, composing: bool) -> Result<Observation, &'static str> {
        self.composing = composing;
        if value != self.value {
            self.revision = self
                .revision
                .checked_add(1)
                .ok_or("native edit revision exhausted")?;
            self.value.clear();
            self.value.push_str(value);
            self.deferred = None;
            return Ok(Observation {
                changed: true,
                replace: false,
            });
        }
        if !composing
            && let Some(deferred) = self.deferred.take()
            && deferred.revision >= self.revision
            && deferred.revision >= self.acknowledged
        {
            self.value = deferred.value;
            return Ok(Observation {
                changed: false,
                replace: true,
            });
        }
        Ok(Observation::default())
    }

    /// Returns true only when the actual editor must change. In particular an
    /// equal acknowledgement must not touch its selection, undo stack or IME.
    pub fn reconcile(&mut self, value: &str, acknowledgement: u64) -> bool {
        if acknowledgement < self.acknowledged {
            return false;
        }
        self.acknowledged = acknowledgement;
        if acknowledgement < self.revision {
            return false;
        }
        self.revision = acknowledgement;
        if value == self.value {
            self.deferred = None;
            return false;
        }
        if self.composing {
            self.deferred = Some(Deferred {
                value: value.to_owned(),
                revision: acknowledgement,
            });
            return false;
        }
        self.deferred = None;
        self.value.clear();
        self.value.push_str(value);
        true
    }

    /// Deferred transforms belong to the declaration's generation, not the
    /// native draft. A remount must not apply an old worker's transformation.
    pub fn new_generation(&mut self) {
        self.deferred = None;
    }

    /// A remounted generation has never seen drafts not yet acknowledged by
    /// its declaration. Their full value is replayed without inventing an edit.
    pub fn needs_replay(&self, declaration_revision: u64) -> bool {
        declaration_revision < self.revision
    }
}

fn boundary(text: &str, position: usize) -> usize {
    let mut units = 0;
    for ch in text.chars() {
        let next = units + ch.len_utf16();
        if next > position {
            break;
        }
        units = next;
    }
    units
}

/// Map the field editor's UTF-16 selection across a programmatic replacement,
/// preserving positions in the unchanged prefix/suffix and clamping positions
/// inside the replacement. Never place a native caret inside a surrogate pair.
pub fn selection_after_replacement(old: &str, new: &str, selection: [usize; 2]) -> [usize; 2] {
    let prefix_bytes = old
        .chars()
        .zip(new.chars())
        .take_while(|(a, b)| a == b)
        .map(|(ch, _)| ch.len_utf8())
        .sum::<usize>();
    let old_tail = &old[prefix_bytes..];
    let new_tail = &new[prefix_bytes..];
    let suffix_units = old_tail
        .chars()
        .rev()
        .zip(new_tail.chars().rev())
        .take_while(|(a, b)| a == b)
        .map(|(ch, _)| ch.len_utf16())
        .sum::<usize>();
    let prefix_units = old[..prefix_bytes].encode_utf16().count();
    let old_end = old.encode_utf16().count() - suffix_units;
    let new_end = new.encode_utf16().count() - suffix_units;
    let map = |position: usize| {
        let mapped = if position < prefix_units {
            position
        } else if position >= old_end {
            new_end.saturating_add(position - old_end)
        } else {
            prefix_units + (position - prefix_units).min(new_end - prefix_units)
        };
        boundary(new, mapped)
    };
    let start = map(selection[0]);
    let end = map(selection[0].saturating_add(selection[1])).max(start);
    [start, end - start]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_echo_advances_acknowledgement_without_replacing_a_newer_draft() {
        let mut text = TextState::new("".into(), 0);
        assert!(text.observe("a", false).unwrap().changed);
        assert!(text.observe("ab", false).unwrap().changed);
        assert!(!text.reconcile("a", 1));
        assert_eq!(
            (&*text.value, text.revision, text.acknowledged),
            ("ab", 2, 1)
        );
        assert!(!text.reconcile("ab", 2));
        assert_eq!(text.acknowledged, 2);
        assert!(!text.reconcile("OLD", 1));
        assert_eq!(text.value, "ab");
    }

    #[test]
    fn composition_defers_transform_until_native_unmark_without_a_value_change() {
        let mut text = TextState::new("".into(), 0);
        text.observe("あ", true).unwrap();
        assert!(!text.reconcile("ア", 1));
        assert_eq!(text.value, "あ");
        assert_eq!(text.observe("あ", true).unwrap(), Observation::default());
        assert_eq!(
            text.observe("あ", false).unwrap(),
            Observation {
                changed: false,
                replace: true
            }
        );
        assert_eq!((&*text.value, text.revision), ("ア", 1));
    }

    #[test]
    fn another_composition_edit_invalidates_deferred_transform() {
        let mut text = TextState::new("".into(), 0);
        text.observe("あ", true).unwrap();
        text.reconcile("ア", 1);
        text.observe("あい", true).unwrap();
        assert_eq!(text.observe("あい", false).unwrap(), Observation::default());
        assert_eq!(
            (&*text.value, text.revision, text.acknowledged),
            ("あい", 2, 1)
        );
    }

    #[test]
    fn equal_ack_cancels_a_deferred_transform_without_touching_composition() {
        let mut text = TextState::new("".into(), 0);
        text.observe("あ", true).unwrap();
        text.reconcile("ア", 1);
        assert!(!text.reconcile("あ", 1));
        assert!(!text.observe("あ", false).unwrap().replace);
        assert_eq!(text.value, "あ");
    }

    #[test]
    fn remount_replays_full_pending_draft_without_resetting_native_revision() {
        let mut text = TextState::new("x".into(), 7);
        text.observe("xy😀", true).unwrap();
        assert!(!text.reconcile("x", 7));
        assert!(text.needs_replay(7));
        assert_eq!((&*text.value, text.revision), ("xy😀", 8));
        assert!(!text.reconcile("xy😀", 8));
        assert!(!text.needs_replay(8));
    }

    #[test]
    fn newer_ack_replaces_older_deferred_value_but_stale_ack_does_not() {
        let mut text = TextState::new("".into(), 0);
        text.observe("あ", true).unwrap();
        text.reconcile("first", 1);
        text.reconcile("latest", 3);
        text.reconcile("stale", 2);
        assert!(text.observe("あ", false).unwrap().replace);
        assert_eq!(
            (&*text.value, text.revision, text.acknowledged),
            ("latest", 3, 3)
        );
    }

    #[test]
    fn duplicate_observation_is_not_a_second_event() {
        let mut text = TextState::new("".into(), 0);
        text.observe("a", false).unwrap();
        assert_eq!(text.observe("a", false).unwrap(), Observation::default());
        assert_eq!(text.revision, 1);
    }

    #[test]
    fn remount_discards_old_generation_transformation_but_retains_composing_draft() {
        let mut text = TextState::new("".into(), 0);
        text.observe("あ", true).unwrap();
        text.reconcile("old worker transform", 1);
        text.new_generation();
        assert!(!text.reconcile("", 0));
        assert!(text.needs_replay(0));
        assert!(!text.observe("あ", false).unwrap().replace);
        assert_eq!((&*text.value, text.revision), ("あ", 1));
    }

    #[test]
    fn transformed_selection_preserves_suffix_and_utf16_boundaries() {
        assert_eq!(
            selection_after_replacement("hello world", "hello big world", [6, 5]),
            [10, 5]
        );
        assert_eq!(selection_after_replacement("abc", "ABC", [1, 1]), [1, 1]);
        assert_eq!(selection_after_replacement("a😀z", "a🐱z", [3, 1]), [3, 1]);
        assert_eq!(selection_after_replacement("abc", "😀", [1, 1]), [0, 2]);
        assert_eq!(selection_after_replacement("abcdef", "a", [5, 1]), [1, 0]);
    }
}
