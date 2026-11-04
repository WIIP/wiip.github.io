(() => {
    const nav = document.querySelector('.site-nav');
    if (!nav) return;
    const toggle = nav.querySelector('.site-menu-toggle');
    const primary = nav.querySelector('.site-primary');
    const mobile = window.matchMedia('(max-width: 767.98px)');
    const groups = [...nav.querySelectorAll('.site-nav-group')];
    const closeGroups = () => groups.forEach(group => { group.open = false; });
    const setExpanded = expanded => {
        toggle.setAttribute('aria-expanded', String(expanded));
        primary.hidden = !expanded;
    };
    const reset = () => {
        closeGroups();
        setExpanded(!mobile.matches);
    };
    reset();
    mobile.addEventListener('change', reset);
    toggle.addEventListener('click', () => {
        const expanded = toggle.getAttribute('aria-expanded') !== 'true';
        setExpanded(expanded);
        if (!expanded) closeGroups();
    });
    document.addEventListener('click', event => {
        if (!nav.contains(event.target)) closeGroups();
    });
    nav.addEventListener('keydown', event => {
        if (event.key !== 'Escape') return;
        const currentGroup = event.target.closest('.site-nav-group[open]');
        const openGroup = currentGroup || groups.find(group => group.open);
        if (openGroup) {
            closeGroups();
            openGroup.querySelector('summary').focus();
        } else if (mobile.matches && !primary.hidden) {
            setExpanded(false);
            toggle.focus();
        }
    });
})();
