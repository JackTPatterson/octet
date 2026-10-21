import Foundation

/// The page side of Browser Control. `agent` runs in Octet's own content
/// world, out of the page's reach, and does the snapshot (a uid per element
/// it lists), input, styles and audits. `hooks` runs in the page's world
/// from the document's start, as it has to for the page's own console and
/// fetch, and only reports what it sees.
enum BrowserAgentScripts {
    static let agent = #"""
    (() => {
    if (globalThis.octetAgent) return;
    const doc = document;
    const gen = Math.random().toString(36).slice(2, 6);
    let next = 1;
    const nodes = new Map();
    const ids = new WeakMap();
    const uidOf = (el) => {
      let id = ids.get(el);
      if (!id) { id = gen + '_' + (next++); ids.set(el, id); nodes.set(id, new WeakRef(el)); }
      return id;
    };
    const resolve = (uid) => {
      const el = nodes.get(String(uid))?.deref();
      if (!el || !el.isConnected) throw new Error('No element with uid ' + uid + ' on the page now. Take a new snapshot.');
      return el;
    };
    const clean = (s, max = 160) => {
      s = String(s ?? '').replace(/\s+/g, ' ').trim();
      return s.length > max ? s.slice(0, max - 1) + '…' : s;
    };
    const q = (s) => JSON.stringify(s);

    // MARK: roles and names
    const landmarks = { nav: 'navigation', main: 'main', aside: 'complementary', form: 'form', dialog: 'dialog',
      ul: 'list', ol: 'list', menu: 'list', li: 'listitem', table: 'table', thead: 'rowgroup', tbody: 'rowgroup', tfoot: 'rowgroup',
      tr: 'row', th: 'columnheader', td: 'cell', textarea: 'textbox', option: 'option', optgroup: 'group', fieldset: 'group',
      details: 'group', summary: 'button', progress: 'progressbar', meter: 'meter', hr: 'separator', figure: 'figure',
      article: 'article', iframe: 'Iframe', video: 'video', audio: 'audio', output: 'status', dl: 'list', dt: 'term', dd: 'definition',
      blockquote: 'blockquote', code: 'code', pre: 'code', label: 'LabelText', legend: 'legend', caption: 'caption' };
    const inputRoles = { button: 'button', submit: 'button', reset: 'button', image: 'button', checkbox: 'checkbox', radio: 'radio',
      range: 'slider', number: 'spinbutton', search: 'searchbox', email: 'textbox', tel: 'textbox', text: 'textbox', url: 'textbox',
      password: 'textbox', date: 'textbox', 'datetime-local': 'textbox', month: 'textbox', week: 'textbox', time: 'textbox',
      color: 'button', file: 'button' };
    const roleOf = (el) => {
      const explicit = el.getAttribute('role');
      if (explicit) return explicit.split(' ')[0];
      const tag = el.localName;
      if (tag === 'a' || tag === 'area') return el.hasAttribute('href') ? 'link' : null;
      if (tag === 'button') return 'button';
      if (tag === 'input') return el.type === 'hidden' ? null : (inputRoles[el.type] || 'textbox');
      if (tag === 'select') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      if (tag === 'img') return el.getAttribute('alt') === '' ? null : 'image';
      if (tag === 'svg') return el.getAttribute('aria-label') || el.querySelector(':scope > title') ? 'image' : null;
      if (/^h[1-6]$/.test(tag)) return 'heading';
      if (tag === 'header') return el.closest('article, aside, main, nav, section') ? null : 'banner';
      if (tag === 'footer') return el.closest('article, aside, main, nav, section') ? null : 'contentinfo';
      if (tag === 'section') return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
      if (el.isContentEditable && (el.parentElement == null || !el.parentElement.isContentEditable)) return 'textbox';
      return landmarks[tag] || null;
    };
    // Roles whose name is their text: the text isn't listed again under them.
    const nameFromContent = new Set(['button', 'link', 'heading', 'option', 'tab', 'menuitem', 'menuitemcheckbox',
      'menuitemradio', 'treeitem', 'cell', 'columnheader', 'rowheader', 'checkbox', 'radio', 'switch', 'tooltip', 'LabelText',
      'legend', 'caption', 'term', 'code', 'status']);
    // A label's own words, without the controls it wraps (a select's options).
    const ownText = (label) => {
      const copy = label.cloneNode(true);
      for (const control of copy.querySelectorAll('select, textarea, input, button')) control.remove();
      return clean(copy.textContent);
    };
    const labelText = (el) => {
      const parts = [];
      if (el.labels) for (const l of el.labels) parts.push(ownText(l));
      return clean(parts.join(' '));
    };
    const nameOf = (el, role) => {
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const text = by.split(/\s+/).map((id) => doc.getElementById(id)?.innerText || '').join(' ');
        if (clean(text)) return clean(text);
      }
      const aria = el.getAttribute('aria-label');
      if (aria && clean(aria)) return clean(aria);
      const tag = el.localName;
      if (tag === 'input' || tag === 'textarea' || tag === 'select') {
        if (['button', 'submit', 'reset'].includes(el.type)) return clean(el.value || (el.type === 'submit' ? 'Submit' : el.type === 'reset' ? 'Reset' : ''));
        if (el.type === 'image') return clean(el.alt || el.value || 'Submit');
        return labelText(el) || clean(el.getAttribute('placeholder') || el.title || '');
      }
      if (tag === 'img' || tag === 'area') return clean(el.getAttribute('alt') || el.title || '');
      if (tag === 'svg') return clean(el.querySelector(':scope > title')?.textContent || '');
      if (tag === 'iframe') return clean(el.title || el.name || '');
      if (tag === 'fieldset') return clean(el.querySelector(':scope > legend')?.innerText || '');
      if (tag === 'table') return clean(el.querySelector(':scope > caption')?.innerText || '');
      if (tag === 'label') return ownText(el);
      if (nameFromContent.has(role) || tag === 'summary') return clean(el.innerText || el.textContent || el.title || '');
      return clean(el.title || '');
    };
    const hidden = (el) => {
      if (el.getAttribute('aria-hidden') === 'true') return true;
      if (el.localName === 'template' || el.localName === 'script' || el.localName === 'style' || el.localName === 'noscript' || el.localName === 'head') return true;
      if (el.checkVisibility) return !el.checkVisibility({ visibilityProperty: true, opacityProperty: false });
      const style = getComputedStyle(el);
      return style.display === 'none' || style.visibility === 'hidden';
    };
    const focusable = (el) => el.matches?.('a[href], button, input, select, textarea, summary, [tabindex], [contenteditable=""], [contenteditable="true"], iframe');
    const props = (el, role) => {
      const out = [];
      const tag = el.localName;
      const attr = (name) => el.getAttribute(name);
      if (role === 'heading') out.push('level="' + (attr('aria-level') || tag.slice(1)) + '"');
      if (role === 'link' && el.href) out.push('url=' + q(el.href));
      if (tag === 'input' || tag === 'textarea') {
        if (el.type === 'checkbox' || el.type === 'radio') { if (el.checked) out.push('checked'); }
        else if (el.type === 'password') { if (el.value) out.push('value="••••"'); }
        else if (el.type !== 'file' && el.value) out.push('value=' + q(clean(el.value, 200)));
        if (el.type === 'file' && el.files?.length) out.push('files=' + q([...el.files].map((f) => f.name).join(', ')));
        if (el.required) out.push('required');
        if (el.readOnly) out.push('readonly');
        if (el.multiple) out.push('multiselectable');
      } else if (tag === 'select') {
        const chosen = [...el.selectedOptions].map((o) => clean(o.text)).join(', ');
        if (chosen) out.push('value=' + q(chosen));
        if (el.required) out.push('required');
      } else if (el.isContentEditable && role === 'textbox') {
        const text = clean(el.innerText, 200);
        if (text) out.push('value=' + q(text));
        out.push('multiline');
      } else if (tag === 'option') {
        if (el.selected) out.push('selected');
      } else if (tag === 'img' && el.src) {
        out.push('url=' + q(el.currentSrc || el.src));
      }
      const checked = attr('aria-checked');
      if (checked === 'true') out.push('checked'); else if (checked === 'mixed') out.push('checked="mixed"');
      if (attr('aria-pressed') === 'true') out.push('pressed');
      if (attr('aria-selected') === 'true') out.push('selected');
      const expanded = attr('aria-expanded');
      if (expanded) out.push(expanded === 'true' ? 'expanded' : 'collapsed');
      else if (tag === 'details') out.push(el.open ? 'expanded' : 'collapsed');
      if (attr('aria-haspopup') && attr('aria-haspopup') !== 'false') out.push('haspopup="' + attr('aria-haspopup') + '"');
      if (el.disabled || attr('aria-disabled') === 'true') out.push('disabled');
      if (attr('aria-invalid') === 'true' || (el.validity && el.matches?.(':user-invalid'))) out.push('invalid');
      if (role === 'slider' || role === 'progressbar' || role === 'meter' || role === 'spinbutton') {
        const now = attr('aria-valuenow') ?? el.value;
        if (now != null && now !== '' && !out.some((p) => p.startsWith('value='))) out.push('value="' + now + '"');
      }
      if (el.localName === 'iframe') {
        try { if (!el.contentDocument) out.push('cross-origin'); } catch { out.push('cross-origin'); }
      }
      if (doc.activeElement === el || el.shadowRoot?.activeElement) out.push('focused');
      if (el.matches?.('dialog[open], [aria-modal="true"]')) out.push('modal');
      return out;
    };

    // MARK: snapshot
    const snapshot = (verbose = false, maxLines = 4000) => {
      const lines = [];
      let truncated = false;
      const emit = (depth, text) => {
        if (lines.length >= maxLines) { truncated = true; return false; }
        lines.push('  '.repeat(depth) + text);
        return true;
      };
      const walk = (node, depth, nameHolder) => {
        if (truncated) return;
        if (node.nodeType === Node.TEXT_NODE) {
          if (nameHolder) return;
          const text = clean(node.textContent, 300);
          if (text) emit(depth, 'StaticText ' + q(text));
          return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
        const el = node;
        if (node.nodeType === Node.ELEMENT_NODE && hidden(el)) return;
        let childDepth = depth;
        let holder = nameHolder;
        if (node.nodeType === Node.ELEMENT_NODE) {
          let role = roleOf(el);
          if (!role && verbose) role = 'generic';
          if (!role && focusable(el) && el.localName !== 'div') role = 'generic';
          if (!role && (el.onclick || el.getAttribute('onclick') != null || getComputedStyle(el).cursor === 'pointer') && !el.parentElement?.closest?.('a, button, [role=button]') && el.childElementCount < 4 && clean(el.innerText, 60)) role = 'clickable';
          if (role && role !== 'none' && role !== 'presentation') {
            const name = nameOf(el, role);
            let line = 'uid=' + uidOf(el) + ' ' + role + (name ? ' ' + q(name) : '');
            if (verbose && role === 'generic') line += ' <' + el.localName + (el.id ? '#' + el.id : '') + '>';
            const extra = props(el, role);
            if (extra.length) line += ' ' + extra.join(' ');
            if (!emit(depth, line)) return;
            childDepth = depth + 1;
            if (nameFromContent.has(role) || role === 'clickable' || role === 'image' || role === 'textbox' && el.isContentEditable) holder = true;
          }
          if (el.localName === 'iframe') {
            let inner = null;
            try { inner = el.contentDocument; } catch {}
            if (inner?.body) walk(inner.body, childDepth, false);
            return;
          }
          if (el.localName === 'select') {
            for (const option of el.options) {
              emit(childDepth, 'uid=' + uidOf(option) + ' option ' + q(clean(option.text)) + (option.selected ? ' selected' : '') + (option.disabled ? ' disabled' : ''));
            }
            return;
          }
          if (el.localName === 'textarea' || el.localName === 'input') return;
          // A shadow root draws the light children through its slots.
          if (el.shadowRoot) { walk(el.shadowRoot, childDepth, holder); return; }
        }
        const children = el.localName === 'slot' ? el.assignedNodes({ flatten: true }) : el.childNodes;
        for (const child of children) { walk(child, childDepth, holder); if (truncated) return; }
      };
      const root = doc.documentElement;
      lines.push('uid=' + uidOf(root) + ' RootWebArea ' + q(doc.title || '') + ' url=' + q(location.href));
      if (doc.body) walk(doc.body, 1, false);
      if (truncated) lines.push('… (snapshot cut at ' + maxLines + ' lines; use evaluate_script or a more specific page to read the rest)');
      return lines.join('\n');
    };

    // MARK: input
    const settle = (quietMs = 200, maxMs = 2000) => new Promise((done) => {
      let timer;
      const finish = () => { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); done(); };
      const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(finish, quietMs); });
      observer.observe(doc, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(finish, quietMs);
      const cap = setTimeout(finish, maxMs);
    });
    const center = (el) => {
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
    };
    const target = (el) => {
      const p = center(el);
      const top = doc.elementFromPoint(p.x, p.y);
      const hit = top && (top === el || el.contains(top)) ? top : el;
      const covered = top && !(top === el || el.contains(top) || top.contains(el)) ? top : null;
      return { p, hit, covered };
    };
    const mouse = (el, type, p, extra = {}) => {
      const init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: p.x, clientY: p.y, screenX: p.x, screenY: p.y,
        button: 0, buttons: type.endsWith('down') || type === 'mousemove' && extra.buttons ? 1 : 0, ...extra };
      const Ctor = type.startsWith('pointer') ? PointerEvent : type.startsWith('drag') || type === 'drop' ? DragEvent : MouseEvent;
      if (Ctor === PointerEvent) Object.assign(init, { pointerId: 1, pointerType: 'mouse', isPrimary: true });
      return el.dispatchEvent(new Ctor(type, init));
    };
    const hoverSeq = (el, p) => {
      for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) mouse(el, type, p);
    };
    const describe = (el) => {
      const role = roleOf(el) || el.localName;
      const name = nameOf(el, role);
      return role + (name ? ' ' + q(name) : '');
    };
    const coveredNote = (covered) => covered ? ' (note: ' + describe(covered) + ' is on top of it at that point)' : '';
    const click = async (uid, dbl) => {
      const el = resolve(uid);
      if (el.disabled) throw new Error(describe(el) + ' is disabled.');
      const { p, hit, covered } = target(el);
      hoverSeq(hit, p);
      const times = dbl ? 2 : 1;
      for (let i = 1; i <= times; i++) {
        mouse(hit, 'pointerdown', p, { detail: i });
        if (mouse(hit, 'mousedown', p, { detail: i }) && focusable(el)) el.focus({ preventScroll: true });
        mouse(hit, 'pointerup', p, { detail: i });
        mouse(hit, 'mouseup', p, { detail: i });
        // click() runs the element's own activation: links, labels, checkboxes, submit.
        if (hit === el && typeof el.click === 'function') el.click(); else mouse(hit, 'click', p, { detail: i });
      }
      if (dbl) mouse(hit, 'dblclick', p, { detail: 2 });
      return (dbl ? 'Double clicked ' : 'Clicked ') + describe(el) + coveredNote(covered);
    };
    const hover = (uid) => {
      const el = resolve(uid);
      const { p, hit, covered } = target(el);
      hoverSeq(hit, p);
      return 'Hovered over ' + describe(el) + coveredNote(covered);
    };
    const drag = (fromUid, toUid) => {
      const from = resolve(fromUid), to = resolve(toUid);
      const a = center(from);
      const data = new DataTransfer();
      mouse(from, 'pointerdown', a); mouse(from, 'mousedown', a);
      mouse(from, 'dragstart', a, { dataTransfer: data });
      const b = center(to);
      for (const type of ['pointermove', 'mousemove']) mouse(to, type, b, { buttons: 1 });
      mouse(to, 'dragenter', b, { dataTransfer: data });
      mouse(to, 'dragover', b, { dataTransfer: data });
      mouse(to, 'drop', b, { dataTransfer: data });
      mouse(from, 'dragend', b, { dataTransfer: data });
      mouse(to, 'pointerup', b); mouse(to, 'mouseup', b);
      return 'Dragged ' + describe(from) + ' onto ' + describe(to);
    };
    const nativeSet = (el, value) => {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    // Typing through the editing commands fires beforeinput and input as a
    // person's typing does, which frameworks' controlled inputs listen for.
    const insert = (el, text, replace) => {
      el.focus({ preventScroll: true });
      if (replace) {
        if (el.select && el.localName !== 'select') el.select(); else doc.execCommand('selectAll');
      }
      const ok = text === '' ? doc.execCommand('delete') : doc.execCommand('insertText', false, text);
      const now = el.isContentEditable ? el.innerText : el.value;
      if (!ok || (!el.isContentEditable && replace && now !== text)) {
        if (el.isContentEditable) el.textContent = text; else nativeSet(el, replace ? text : (el.value || '') + text);
      }
    };
    const fillOne = (uid, value) => {
      const el = resolve(uid);
      value = String(value);
      const tag = el.localName;
      if (tag === 'select') {
        const wanted = value.split(/\s*,\s*/);
        const pick = (o) => wanted.includes(o.value) || wanted.includes(clean(o.text));
        if (![...el.options].some(pick)) throw new Error('No option ' + q(value) + ' in ' + describe(el) + '. Options: ' + [...el.options].map((o) => q(clean(o.text))).join(', '));
        if (el.multiple) { for (const o of el.options) o.selected = pick(o); }
        else el.value = [...el.options].find(pick).value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return 'Selected ' + q(value) + ' in ' + describe(el);
      }
      if (tag === 'option') {
        const select = el.closest('select');
        if (select) return fillOne(uidOf(select), el.value);
      }
      const checkable = (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) || ['checkbox', 'radio', 'switch', 'menuitemcheckbox'].includes(el.getAttribute('role'));
      if (checkable) {
        const want = value === 'true';
        const is = tag === 'input' ? el.checked : el.getAttribute('aria-checked') === 'true';
        if (want !== is) el.click();
        return (want ? 'Checked ' : 'Unchecked ') + describe(el);
      }
      if (tag === 'input' && ['date', 'datetime-local', 'month', 'week', 'time', 'color', 'range', 'number'].includes(el.type)) {
        el.focus({ preventScroll: true });
        nativeSet(el, value);
        return 'Set ' + describe(el) + ' to ' + q(value);
      }
      if (tag === 'input' && el.type === 'file') throw new Error('Use upload_file for file inputs.');
      let field = el;
      if (!(tag === 'input' || tag === 'textarea' || el.isContentEditable)) {
        field = el.querySelector('input, textarea, [contenteditable=""], [contenteditable="true"]');
        if (!field) throw new Error(describe(el) + " isn't something to type into.");
      }
      if (field.disabled || field.readOnly) throw new Error(describe(field) + ' is ' + (field.disabled ? 'disabled' : 'read only') + '.');
      insert(field, value, true);
      field.dispatchEvent(new Event('change', { bubbles: true }));
      return 'Filled ' + describe(field) + (field.type === 'password' ? '' : ' with ' + q(clean(value, 80)));
    };
    const fill = async (uid, value) => fillOne(uid, value);
    const fillForm = async (elements) => elements.map((e) => fillOne(e.uid, e.value)).join('\n');
    const typeText = async (text) => {
      const el = doc.activeElement;
      if (!el || el === doc.body) throw new Error('Nothing on the page has focus. Click the field first, or use fill.');
      const editable = el.isContentEditable || el.localName === 'textarea' || (el.localName === 'input' && !['checkbox', 'radio', 'button', 'submit', 'file'].includes(el.type));
      if (!editable) throw new Error(describe(el) + " has focus, and it isn't a text field.");
      insert(el, text, false);
      return 'Typed into ' + describe(el);
    };
    const keyCodes = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ' ': 32, Space: 32, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39,
      ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34 };
    const codeOf = (key) => {
      if (/^[a-z]$/i.test(key)) return 'Key' + key.toUpperCase();
      if (/^[0-9]$/.test(key)) return 'Digit' + key;
      if (key === ' ') return 'Space';
      return key;
    };
    const tabOrder = () => [...doc.querySelectorAll('a[href], button, input, select, textarea, summary, [tabindex], [contenteditable=""], [contenteditable="true"]')]
      .filter((el) => !el.disabled && el.tabIndex >= 0 && !hidden(el) && el.type !== 'hidden');
    const pressKey = async (combo) => {
      const parts = combo === '+' ? ['+'] : combo.split(/\+(?=.)/);
      const mods = { Control: false, Shift: false, Alt: false, Meta: false };
      let key = parts.pop();
      for (const m of parts) {
        const name = { Ctrl: 'Control', Cmd: 'Meta', Command: 'Meta', Option: 'Alt', ControlOrMeta: 'Meta' }[m] || m;
        if (!(name in mods)) throw new Error('Unknown modifier ' + m + '. Use Control, Shift, Alt or Meta.');
        mods[name] = true;
      }
      if (key === 'Space') key = ' ';
      const el = doc.activeElement && doc.activeElement !== doc.documentElement ? doc.activeElement : doc.body;
      const init = { key, code: codeOf(key), keyCode: keyCodes[key] ?? (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0),
        which: keyCodes[key] ?? 0, bubbles: true, cancelable: true, composed: true,
        ctrlKey: mods.Control, shiftKey: mods.Shift, altKey: mods.Alt, metaKey: mods.Meta };
      const allowed = el.dispatchEvent(new KeyboardEvent('keydown', init));
      const command = mods.Control || mods.Meta;
      let did = '';
      if (allowed) {
        const editable = el.isContentEditable || el.localName === 'textarea' || el.localName === 'input';
        if (key.length === 1 && !command && !mods.Alt) {
          el.dispatchEvent(new KeyboardEvent('keypress', init));
          if (editable) { doc.execCommand('insertText', false, key); did = ' (typed ' + q(key) + ')'; }
          else if (key === ' ' && (el.localName === 'button' || el.getAttribute('role') === 'button' || el.type === 'checkbox')) { el.click(); did = ' (activated it)'; }
        } else if (key === 'Enter' && !command) {
          el.dispatchEvent(new KeyboardEvent('keypress', init));
          if (el.localName === 'textarea' || el.isContentEditable) { doc.execCommand('insertParagraph'); }
          else if (el.localName === 'input' && el.form) { el.form.requestSubmit(); did = ' (submitted the form)'; }
          else if (el.localName === 'a' || el.localName === 'button' || el.getAttribute('role') === 'button' || el.localName === 'summary') { el.click(); did = ' (activated it)'; }
        } else if (key === 'Tab') {
          const order = tabOrder();
          const i = order.indexOf(el);
          const nextEl = order[(i + (mods.Shift ? -1 : 1) + order.length) % order.length];
          nextEl?.focus();
          if (nextEl) did = ' (focus moved to ' + describe(nextEl) + ')';
        } else if (key === 'Backspace' && editable) { doc.execCommand('delete'); }
        else if (key === 'Delete' && editable) { doc.execCommand('forwardDelete'); }
        else if (command && key.toLowerCase() === 'a') { if (el.select) el.select(); else doc.execCommand('selectAll'); }
        else if (key === 'Escape' && el.blur && editable) { /* left to the page */ }
        else if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End'].includes(key) && !editable) {
          const step = { ArrowDown: 40, ArrowUp: -40, PageDown: innerHeight * 0.9, PageUp: -innerHeight * 0.9 }[key];
          if (key === 'Home') scrollTo(0, 0); else if (key === 'End') scrollTo(0, doc.documentElement.scrollHeight); else scrollBy(0, step);
        }
      }
      (doc.activeElement || el).dispatchEvent(new KeyboardEvent('keyup', init));
      return 'Pressed ' + combo + (allowed ? '' : ' (the page handled it)') + did;
    };
    const upload = async (uid, files) => {
      let el = resolve(uid);
      if (!(el.localName === 'input' && el.type === 'file')) {
        el = el.control || el.querySelector?.('input[type=file]') || el.closest('label')?.control
          || el.parentElement?.querySelector('input[type=file]') || doc.querySelectorAll('input[type=file]').length === 1 && doc.querySelector('input[type=file]');
        if (!el || el.type !== 'file') throw new Error("Couldn't find the file input for that element. Take a verbose snapshot and pass the input's uid.");
      }
      const data = new DataTransfer();
      for (const f of files) {
        const bytes = Uint8Array.from(atob(f.data), (c) => c.charCodeAt(0));
        data.items.add(new File([bytes], f.name, { type: f.type }));
      }
      el.files = data.files;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return 'Uploaded ' + files.map((f) => f.name).join(', ') + ' through ' + describe(el);
    };
    const waitFor = async (texts, timeout) => {
      const end = Date.now() + timeout;
      while (true) {
        const body = doc.body?.innerText || '';
        const found = texts.find((t) => body.includes(t) || doc.title.includes(t));
        if (found != null) return found;
        if (Date.now() > end) throw new Error('Timed out after ' + timeout + ' ms waiting for ' + texts.map(q).join(' or ') + '.');
        await new Promise((r) => setTimeout(r, 100));
      }
    };
    const markArgs = (uids, token) => uids.map((uid, i) => { resolve(uid).setAttribute('data-octet-arg', token + '-' + i); return i; }).length;

    // MARK: geometry
    const rect = (uid) => {
      const el = resolve(uid);
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      return { x: r.left, y: r.top, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight };
    };
    const extent = () => ({ width: Math.max(doc.documentElement.scrollWidth, doc.body?.scrollWidth || 0),
      height: Math.max(doc.documentElement.scrollHeight, doc.body?.scrollHeight || 0), viewportWidth: innerWidth, viewportHeight: innerHeight,
      scrollX, scrollY });

    // MARK: styles
    const inherited = ['color', 'font-family', 'font-size', 'font-weight', 'font-style', 'line-height', 'letter-spacing', 'text-align',
      'text-transform', 'white-space', 'visibility', 'cursor', 'direction', 'word-spacing', 'list-style'];
    const rulesFor = (el) => {
      const matched = [];
      let blocked = 0;
      const visit = (rules, sheet, media) => {
        for (const rule of rules) {
          if (rule.selectorText) {
            let hit = false;
            try { hit = el.matches(rule.selectorText); } catch {}
            if (hit) matched.push({ selector: rule.selectorText, css: rule.style.cssText, source: sheet.href || 'inline <style>', media });
          }
          if (rule.cssRules && !rule.selectorText) {
            const cond = rule.media ? rule.media.mediaText : rule.conditionText;
            const applies = rule.media ? matchMedia(rule.media.mediaText).matches : true;
            if (applies) visit(rule.cssRules, sheet, cond || media);
          }
        }
      };
      const sheets = [...doc.styleSheets, ...(doc.adoptedStyleSheets || [])];
      for (const sheet of sheets) {
        let rules;
        try { rules = sheet.cssRules; } catch { blocked++; continue; }
        if (rules) visit(rules, sheet, null);
      }
      return { matched: matched.reverse(), blocked };
    };
    const styles = (uid, pageIdx, pageSize) => {
      const el = resolve(uid);
      const { matched, blocked } = rulesFor(el);
      const out = ['Styles for ' + describe(el) + ' <' + el.localName + (el.id ? '#' + el.id : '') + (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).join('.') : '') + '>'];
      if (el.getAttribute('style')) out.push('', 'Inline style: ' + el.getAttribute('style'));
      const start = pageIdx * pageSize;
      const page = matched.slice(start, start + pageSize);
      out.push('', 'Matched rules ' + (matched.length ? (start + 1) + '–' + (start + page.length) + ' of ' + matched.length : 'none') + ', most specific source order last first:');
      for (const r of page) out.push('  ' + r.selector + ' { ' + r.css + ' }  /* ' + r.source + (r.media ? ' @' + r.media : '') + ' */');
      if (start + pageSize < matched.length) out.push('  … more on pageIdx ' + (pageIdx + 1));
      if (blocked) out.push('  (' + blocked + ' cross-origin stylesheet' + (blocked > 1 ? 's' : '') + ' could not be read)');
      if (pageIdx === 0) {
        const computed = getComputedStyle(el);
        const keys = ['display', 'position', 'box-sizing', 'width', 'height', 'margin', 'padding', 'border', 'color', 'background-color',
          'font-family', 'font-size', 'font-weight', 'line-height', 'z-index', 'opacity', 'overflow', 'flex', 'grid-template-columns', 'gap', 'transform'];
        out.push('', 'Computed:');
        for (const k of keys) { const v = computed.getPropertyValue(k); if (v) out.push('  ' + k + ': ' + v); }
        const parent = el.parentElement;
        if (parent) {
          const pc = getComputedStyle(parent);
          const from = inherited.filter((k) => pc.getPropertyValue(k) === computed.getPropertyValue(k) && !el.style.getPropertyValue(k));
          if (from.length) out.push('', 'Inherited from <' + parent.localName + '> (same value as the parent): ' + from.join(', '));
        }
      }
      return out.join('\n');
    };

    // MARK: performance
    const perf = { entries: {}, observers: [] };
    const types = PerformanceObserver.supportedEntryTypes || [];
    const startRecording = () => {
      perf.entries = { 'largest-contentful-paint': [], 'layout-shift': [], longtask: [], event: [] };
      for (const type of Object.keys(perf.entries)) {
        if (!types.includes(type)) continue;
        const observer = new PerformanceObserver((list) => perf.entries[type].push(...list.getEntries()));
        try { observer.observe({ type, buffered: true, ...(type === 'event' ? { durationThreshold: 40 } : {}) }); perf.observers.push(observer); } catch {}
      }
      return true;
    };
    const metrics = () => {
      const nav = performance.getEntriesByType('navigation')[0];
      const paints = Object.fromEntries(performance.getEntriesByType('paint').map((p) => [p.name, p.startTime]));
      const lcpList = perf.entries['largest-contentful-paint'] || [];
      const lcp = lcpList[lcpList.length - 1];
      const cls = (perf.entries['layout-shift'] || []).filter((e) => !e.hadRecentInput).reduce((s, e) => s + e.value, 0);
      const resources = performance.getEntriesByType('resource').map((r) => ({ url: r.name, type: r.initiatorType, start: r.startTime,
        duration: r.duration, transfer: r.transferSize, encoded: r.encodedBodySize, blocking: r.renderBlockingStatus || null }));
      return {
        url: location.href, supported: types,
        navigation: nav ? { ttfb: nav.responseStart - nav.startTime, requestStart: nav.requestStart, responseStart: nav.responseStart,
          responseEnd: nav.responseEnd, domInteractive: nav.domInteractive, domContentLoaded: nav.domContentLoadedEventEnd, load: nav.loadEventEnd,
          dns: nav.domainLookupEnd - nav.domainLookupStart, connect: nav.connectEnd - nav.connectStart, transfer: nav.transferSize,
          redirect: nav.redirectEnd - nav.redirectStart, type: nav.type } : null,
        fcp: paints['first-contentful-paint'] ?? null, fp: paints['first-paint'] ?? null,
        lcp: lcp ? { time: lcp.startTime, size: lcp.size, element: lcp.element ? describe(lcp.element) : null, url: lcp.url || null,
          renderTime: lcp.renderTime, loadTime: lcp.loadTime } : null,
        cls: types.includes('layout-shift') ? cls : null,
        longTasks: (perf.entries.longtask || []).map((t) => ({ start: t.startTime, duration: t.duration })),
        slowEvents: (perf.entries.event || []).map((e) => ({ name: e.name, start: e.startTime, duration: e.duration })),
        resources, domSize: doc.getElementsByTagName('*').length,
      };
    };

    // MARK: audit (a subset of Lighthouse's accessibility, SEO and best-practice checks)
    const audit = () => {
      const results = { accessibility: [], seo: [], 'best-practices': [] };
      const check = (category, id, title, failing, weight = 1) => {
        results[category].push({ id, title, weight, passed: failing.length === 0, items: failing.slice(0, 15).map((el) => typeof el === 'string' ? el : describe(el) + ' ' + (el.id ? '#' + el.id : '<' + el.localName + '>')), count: failing.length });
      };
      const all = (sel) => [...doc.querySelectorAll(sel)].filter((el) => !hidden(el));
      check('accessibility', 'image-alt', 'Images have alt text', all('img:not([alt])'), 3);
      check('accessibility', 'button-name', 'Buttons have an accessible name', all('button, [role=button], input[type=button], input[type=submit]').filter((el) => !nameOf(el, 'button')), 3);
      check('accessibility', 'link-name', 'Links have a discernible name', all('a[href]').filter((el) => !nameOf(el, 'link') && !el.querySelector('img[alt]:not([alt=""])')), 3);
      check('accessibility', 'label', 'Form fields have labels', all('input:not([type=hidden]):not([type=button]):not([type=submit]):not([type=reset]):not([type=image]), select, textarea').filter((el) => !nameOf(el, 'textbox') || nameOf(el, 'textbox') === clean(el.getAttribute('placeholder') || '') && !el.getAttribute('aria-label') && !el.labels?.length), 3);
      check('accessibility', 'html-has-lang', '<html> has a lang attribute', doc.documentElement.lang ? [] : ['<html>'], 2);
      check('accessibility', 'document-title', 'The document has a <title>', doc.title.trim() ? [] : ['<title>'], 2);
      const ids = {}; for (const el of doc.querySelectorAll('[id]')) ids[el.id] = (ids[el.id] || 0) + 1;
      check('accessibility', 'duplicate-id-aria', 'IDs used by ARIA are unique', Object.keys(ids).filter((id) => ids[id] > 1 && doc.querySelector('[aria-labelledby~="' + CSS.escape(id) + '"], [aria-describedby~="' + CSS.escape(id) + '"], label[for="' + CSS.escape(id) + '"]')).map((id) => '#' + id), 1);
      const levels = all('h1, h2, h3, h4, h5, h6').map((h) => +h.localName[1]);
      const skips = []; levels.forEach((l, i) => { if (i && l > levels[i - 1] + 1) skips.push('h' + levels[i - 1] + ' → h' + l); });
      check('accessibility', 'heading-order', 'Headings go down one level at a time', skips, 1);
      check('accessibility', 'frame-title', 'Frames have a title', all('iframe').filter((f) => !f.title), 1);
      check('accessibility', 'meta-viewport', 'Zooming isn’t disabled', [...doc.querySelectorAll('meta[name=viewport]')].filter((m) => /user-scalable\s*=\s*(no|0)|maximum-scale\s*=\s*1(\.0)?\b/.test(m.content)).map(() => 'meta viewport'), 2);
      const lum = (c) => { const m = c.match(/[\d.]+/g); if (!m) return null; const [r, g, b] = m.slice(0, 3).map((v) => { v = v / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
      const bgOf = (el) => { for (let e = el; e; e = e.parentElement) { const c = getComputedStyle(e).backgroundColor; const a = c.match(/[\d.]+/g); if (a && (a.length < 4 || +a[3] > 0.9)) return c; if (getComputedStyle(e).backgroundImage !== 'none') return null; } return 'rgb(255,255,255)'; };
      const low = [];
      for (const el of all('p, span, a, li, td, th, label, button, h1, h2, h3, h4, h5, h6').slice(0, 600)) {
        if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
        const s = getComputedStyle(el); const bg = bgOf(el); if (!bg) continue;
        const a = lum(s.color), b = lum(bg); if (a == null || b == null) continue;
        const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
        const large = parseFloat(s.fontSize) >= 24 || (parseFloat(s.fontSize) >= 18.66 && +s.fontWeight >= 700);
        if (ratio < (large ? 3 : 4.5)) low.push(el);
      }
      check('accessibility', 'color-contrast', 'Text has enough contrast with its background', low, 3);
      const description = doc.querySelector('meta[name=description]')?.content?.trim();
      check('seo', 'document-title', 'The document has a <title>', doc.title.trim() ? [] : ['<title>'], 1);
      check('seo', 'meta-description', 'The document has a meta description', description ? [] : ['<meta name="description">'], 1);
      check('seo', 'viewport', 'Has a <meta name="viewport"> tag', doc.querySelector('meta[name=viewport]') ? [] : ['<meta name="viewport">'], 1);
      const robots = doc.querySelector('meta[name=robots]')?.content || '';
      check('seo', 'is-crawlable', "Page isn't blocked from indexing", /noindex/i.test(robots) ? ['meta robots: ' + robots] : [], 3);
      check('seo', 'link-text', 'Links have descriptive text', all('a[href]').filter((a) => /^(click here|here|more|read more|learn more|link|this)$/i.test(clean(a.innerText))), 1);
      check('seo', 'crawlable-anchors', 'Links are crawlable', all('a').filter((a) => !a.getAttribute('href') || /^javascript:/i.test(a.getAttribute('href'))).filter((a) => !a.getAttribute('role')), 1);
      const canonical = doc.querySelector('link[rel=canonical]')?.href;
      check('seo', 'canonical', 'Has a valid rel=canonical', canonical === undefined || /^https?:/.test(canonical) ? [] : ['canonical ' + canonical], 1);
      check('seo', 'hreflang', 'hreflang links are valid', [...doc.querySelectorAll('link[rel=alternate][hreflang]')].filter((l) => !/^([a-z]{2,3}(-[A-Za-z0-9]+)*|x-default)$/.test(l.hreflang)).map((l) => l.hreflang), 1);
      check('seo', 'image-alt', 'Images have alt text', all('img:not([alt])'), 1);
      check('best-practices', 'is-on-https', 'Uses HTTPS', location.protocol === 'https:' || /^(localhost|127\.|\[::1\])/.test(location.hostname) ? [] : [location.href], 3);
      check('best-practices', 'doctype', 'Page has the HTML doctype', doc.doctype?.name === 'html' ? [] : ['<!DOCTYPE html>'], 1);
      check('best-practices', 'charset', 'Declares a character set', doc.querySelector('meta[charset], meta[http-equiv="Content-Type" i]') ? [] : ['<meta charset>'], 1);
      check('best-practices', 'image-aspect-ratio', 'Images are shown at their aspect ratio', all('img').filter((img) => img.naturalWidth && img.width && img.height && getComputedStyle(img).objectFit === 'fill' && Math.abs(img.naturalWidth / img.naturalHeight - img.width / img.height) > 0.05), 1);
      check('best-practices', 'image-size-responsive', 'Images are sharp enough', all('img').filter((img) => img.naturalWidth && img.width > 32 && img.naturalWidth < img.width * Math.min(devicePixelRatio, 2) * 0.75), 1);
      check('best-practices', 'mixed-content', 'No http resources on an https page', location.protocol === 'https:' ? performance.getEntriesByType('resource').filter((r) => r.name.startsWith('http:')).map((r) => r.name) : [], 2);
      check('best-practices', 'no-document-write', "Doesn't use document.write", [], 1);
      return { url: location.href, title: doc.title, results };
    };

    globalThis.octetAgent = { snapshot, click, hover, drag, fill, fillForm, typeText, pressKey, upload, waitFor, settle, rect, extent,
      styles, startRecording, metrics, audit, markArgs, describeUid: (uid) => describe(resolve(uid)) };
    })();
    """#

    static let hooks = #"""
    (() => {
    if (window.__octetHooks) return;
    Object.defineProperty(window, '__octetHooks', { value: true });
    const post = (body) => { try { window.webkit.messageHandlers.octetAgent.postMessage(body); } catch {} };
    const show = (value, depth = 0) => {
      try {
        if (value instanceof Error) return value.stack ? String(value.stack) : value.name + ': ' + value.message;
        if (typeof value === 'string') return value;
        if (value === undefined) return 'undefined';
        if (typeof value === 'function') return 'ƒ ' + (value.name || 'anonymous') + '()';
        if (value instanceof Element) return '<' + value.localName + (value.id ? '#' + value.id : '') + '>';
        if (typeof value !== 'object' || value === null) return String(value);
        const seen = new WeakSet();
        const text = JSON.stringify(value, (k, v) => {
          if (typeof v === 'object' && v !== null) { if (seen.has(v)) return '[Circular]'; seen.add(v); }
          if (typeof v === 'bigint') return v.toString() + 'n';
          if (typeof v === 'function') return 'ƒ';
          return v;
        });
        return text === undefined ? String(value) : text;
      } catch { return String(value); }
    };
    const levels = ['log', 'debug', 'info', 'error', 'warn', 'dir', 'dirxml', 'table', 'trace', 'clear', 'group', 'groupCollapsed', 'groupEnd', 'assert', 'count', 'timeEnd'];
    const names = { group: 'startGroup', groupCollapsed: 'startGroupCollapsed', groupEnd: 'endGroup' };
    for (const level of levels) {
      const original = console[level];
      if (typeof original !== 'function') continue;
      console[level] = function (...args) {
        try {
          if (level === 'assert') { if (args[0]) return original.apply(this, args); args = args.slice(1); args.unshift('Assertion failed:'); }
          const stack = level === 'error' || level === 'warn' || level === 'trace' || level === 'assert' ? new Error().stack?.split('\n').slice(1).join('\n') : null;
          post({ kind: 'console', type: names[level] || level, text: args.map((a) => show(a)).join(' ').slice(0, 20000), args: args.slice(0, 10).map((a) => show(a).slice(0, 4000)), stack });
        } catch {}
        return original.apply(this, args);
      };
    }
    addEventListener('error', (e) => {
      if (e.target && e.target !== window && e.target.localName) {
        post({ kind: 'console', type: 'error', text: 'Failed to load resource: ' + (e.target.src || e.target.href || '<' + e.target.localName + '>') });
        return;
      }
      post({ kind: 'console', type: 'error', text: 'Uncaught ' + (e.error ? show(e.error) : e.message), stack: e.error?.stack || null, source: e.filename ? e.filename + ':' + e.lineno + ':' + e.colno : null });
    }, true);
    addEventListener('unhandledrejection', (e) => post({ kind: 'console', type: 'error', text: 'Unhandled Promise Rejection: ' + show(e.reason), stack: e.reason?.stack || null }));
    addEventListener('securitypolicyviolation', (e) => post({ kind: 'console', type: 'issue', text: 'Content Security Policy blocked ' + e.blockedURI + ' (' + e.violatedDirective + ')' }));

    const textual = (type) => !type || /json|text|xml|javascript|html|csv|graphql|x-www-form-urlencoded/i.test(type);
    const bodyText = (body) => {
      if (body == null) return null;
      if (typeof body === 'string') return body.slice(0, 200000);
      if (body instanceof URLSearchParams) return body.toString();
      if (body instanceof FormData) return [...body.entries()].map(([k, v]) => k + '=' + (typeof v === 'string' ? v : '[file ' + v.name + ']')).join('&');
      if (body instanceof Blob) return '[blob ' + body.type + ', ' + body.size + ' bytes]';
      if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return '[binary, ' + body.byteLength + ' bytes]';
      return String(body);
    };
    let seq = 0;
    const id = () => 'r' + (++seq) + '-' + Math.random().toString(36).slice(2, 6);
    const originalFetch = window.fetch;
    if (originalFetch) {
      window.fetch = function (input, init) {
        const rid = id();
        const request = input instanceof Request ? input : null;
        const url = new URL(request ? request.url : String(input), location.href).href;
        const method = (init?.method || request?.method || 'GET').toUpperCase();
        const headers = {};
        try { new Headers(init?.headers || request?.headers || {}).forEach((v, k) => { headers[k] = v; }); } catch {}
        post({ kind: 'request', id: rid, resourceType: 'fetch', url, method, requestHeaders: headers, requestBody: bodyText(init?.body), start: performance.now() });
        return originalFetch.apply(this, arguments).then((response) => {
          const responseHeaders = {};
          response.headers.forEach((v, k) => { responseHeaders[k] = v; });
          const type = response.headers.get('content-type') || '';
          post({ kind: 'response', id: rid, status: response.status, statusText: response.statusText, responseHeaders, end: performance.now(), redirected: response.redirected, finalUrl: response.url });
          // Not a stream (it never ends) and not a large body: a copy of either stays in memory.
          const length = +(response.headers.get('content-length') || 0);
          if (textual(type) && !/event-stream|ndjson/i.test(type) && length <= 2000000 && response.type !== 'opaque') {
            response.clone().text().then((text) => post({ kind: 'body', id: rid, responseBody: text.slice(0, 500000), size: text.length })).catch(() => {});
          }
          return response;
        }, (error) => {
          post({ kind: 'response', id: rid, failed: String(error?.message || error), end: performance.now() });
          throw error;
        });
      };
    }
    const XHR = XMLHttpRequest.prototype;
    const open = XHR.open, send = XHR.send, setHeader = XHR.setRequestHeader;
    XHR.open = function (method, url) { this.__octet = { id: id(), method: String(method).toUpperCase(), url: new URL(url, location.href).href, headers: {} }; return open.apply(this, arguments); };
    XHR.setRequestHeader = function (k, v) { if (this.__octet) this.__octet.headers[k.toLowerCase()] = v; return setHeader.apply(this, arguments); };
    XHR.send = function (body) {
      const info = this.__octet;
      if (info) {
        post({ kind: 'request', id: info.id, resourceType: 'xhr', url: info.url, method: info.method, requestHeaders: info.headers, requestBody: bodyText(body), start: performance.now() });
        this.addEventListener('loadend', () => {
          const responseHeaders = {};
          for (const line of (this.getAllResponseHeaders() || '').trim().split(/[\r\n]+/)) { const i = line.indexOf(':'); if (i > 0) responseHeaders[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim(); }
          let text = null;
          try { if ((this.responseType === '' || this.responseType === 'text') && textual(this.getResponseHeader('content-type'))) text = this.responseText.slice(0, 500000); } catch {}
          post({ kind: 'response', id: info.id, status: this.status, statusText: this.statusText, responseHeaders, end: performance.now(), failed: this.status === 0 ? 'failed' : null });
          if (text != null) post({ kind: 'body', id: info.id, responseBody: text, size: text.length });
        });
      }
      return send.apply(this, arguments);
    };
    const NativeSocket = window.WebSocket;
    if (NativeSocket) {
      window.WebSocket = new Proxy(NativeSocket, { construct(target, args) {
        const socket = new target(...args);
        post({ kind: 'request', id: id(), resourceType: 'websocket', url: socket.url, method: 'GET', requestHeaders: {}, start: performance.now() });
        return socket;
      } });
    }
    const typeOf = (entry) => {
      const t = entry.initiatorType;
      if (t === 'fetch' || t === 'xmlhttprequest' || t === 'beacon') return null;
      const font = /\.(woff2?|ttf|otf)(\?|$)/.test(entry.name);
      if (t === 'link' || t === 'css') return font ? 'font' : /\.css(\?|$)/.test(entry.name) || t === 'link' ? 'stylesheet' : 'other';
      if (t === 'script') return 'script';
      if (t === 'img' || t === 'image' || t === 'input') return 'image';
      if (t === 'video' || t === 'audio') return 'media';
      if (t === 'track') return 'texttrack';
      if (/\.(woff2?|ttf|otf)(\?|$)/.test(entry.name)) return 'font';
      return 'other';
    };
    try {
      new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          const type = typeOf(e);
          if (!type) continue;
          post({ kind: 'resource', id: id(), resourceType: type, url: e.name, method: 'GET', start: e.startTime, end: e.responseEnd,
            transferSize: e.transferSize, encodedSize: e.encodedBodySize, status: e.responseStatus || null, initiator: e.initiatorType });
        }
      }).observe({ type: 'resource', buffered: true });
    } catch {}
    })();
    """#
}
