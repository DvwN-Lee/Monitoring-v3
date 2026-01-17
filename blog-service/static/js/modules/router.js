// blog-service/static/js/modules/router.js
// Hash-based SPA Router

const Router = {
    routes: {},
    currentPath: '',

    init(routes, fallback = null) {
        this.routes = routes;
        this.fallback = fallback;
        window.addEventListener('hashchange', () => this.navigate());
        this.navigate();
    },

    navigate() {
        const path = window.location.hash.slice(1) || '/';
        this.currentPath = path;

        if (path === '/') {
            this.routes['/']?.();
        } else if (path === '/posts/new') {
            this.routes['/posts/new']?.('create');
        } else if (path.match(/^\/posts\/\d+$/)) {
            const id = path.split('/')[2];
            this.routes['/posts/:id']?.(id);
        } else if (path.match(/^\/posts\/\d+\/edit$/)) {
            const id = path.split('/')[2];
            this.routes['/posts/:id/edit']?.('edit', id);
        } else if (this.fallback) {
            this.fallback();
        }

        // Trigger callback after navigation
        if (this.onNavigate) {
            this.onNavigate(path);
        }
    },

    go(path) {
        window.location.hash = path;
    },

    back() {
        window.history.back();
    },

    onNavigate: null
};

export default Router;
