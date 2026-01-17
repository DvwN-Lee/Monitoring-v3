// blog-service/static/js/app.js
// Main Application Entry Point - ES Module Version

import State from './modules/state.js';
import Api from './modules/api.js';
import Router from './modules/router.js';
import Modal from './modules/modal.js';
import Toast from './modules/toast.js';
import Auth from './modules/auth.js';
import { loadPosts, showLoading, hideLoading } from './modules/posts.js';
import { loadCategoryCounts, renderCategoryForm } from './modules/categories.js';
import { renderTemplate, hexToRgb } from './modules/utils.js';

// Application initialization
document.addEventListener('DOMContentLoaded', () => {
    Toast.init();
    Modal.init();

    const mainContent = document.getElementById('main-content');

    // Route Handlers
    const loadPostList = async () => {
        State.setCategory('');
        State.setPage(1);
        renderTemplate('post-list-template', mainContent);
        await loadCategoryCounts();
        await loadPosts();
    };

    const showPostDetail = async (id) => {
        renderTemplate('post-detail-template', mainContent);
        try {
            const post = await Api.posts.getById(id);
            const categoryColor = State.getCategoryColor(post.category.slug);
            const categoryColorRgb = hexToRgb(categoryColor);

            // Build title with badge
            const detailTitle = document.getElementById('detail-title');
            detailTitle.textContent = '';
            detailTitle.appendChild(document.createTextNode(post.title + ' '));

            const badge = document.createElement('span');
            badge.className = 'category-badge';
            badge.style.setProperty('--category-color', categoryColor);
            badge.style.setProperty('--category-color-rgb', categoryColorRgb);
            badge.textContent = post.category.name;
            detailTitle.appendChild(badge);

            document.getElementById('detail-category').textContent = '';
            document.getElementById('detail-author').textContent = '\uC791\uC131\uC790: ' + post.author;

            // Render Markdown content with XSS protection
            const detailContent = document.getElementById('detail-content');
            if (window.marked && window.DOMPurify) {
                if (window.hljs) {
                    marked.setOptions({
                        highlight: (code, lang) => {
                            const language = hljs.getLanguage(lang) ? lang : 'plaintext';
                            return hljs.highlight(code, { language }).value;
                        },
                        breaks: true,
                        gfm: true
                    });
                }
                const rawHTML = marked.parse(post.content);
                const cleanHTML = DOMPurify.sanitize(rawHTML);
                detailContent.innerHTML = cleanHTML;
            } else if (window.marked) {
                detailContent.innerHTML = DOMPurify ? DOMPurify.sanitize(marked.parse(post.content)) : marked.parse(post.content);
            } else {
                detailContent.textContent = post.content;
            }

            document.getElementById('back-btn').onclick = () => { window.location.hash = '/'; };

            if (Auth.canEdit(post.author)) {
                document.getElementById('edit-btn').classList.remove('hidden');
                document.getElementById('delete-btn').classList.remove('hidden');
                document.getElementById('edit-btn').onclick = () => { window.location.hash = '/posts/' + id + '/edit'; };
                document.getElementById('delete-btn').onclick = async () => {
                    if (!confirm('\uC0AD\uC81C\uD558\uC2DC\uACA0\uC2B5\uB2C8\uAE4C?')) return;
                    try {
                        await Api.posts.delete(id);
                        Toast.success('\uAC8C\uC2DC\uBB3C\uC774 \uC0AD\uC81C\uB418\uC5C8\uC2B5\uB2C8\uB2E4.');
                        window.location.hash = '/';
                    } catch (err) {
                        Toast.error('\uAC8C\uC2DC\uBB3C \uC0AD\uC81C\uC5D0 \uC2E4\uD328\uD588\uC2B5\uB2C8\uB2E4.');
                    }
                };
            }
        } catch (err) {
            console.error('\uAC8C\uC2DC\uBB3C \uC0C1\uC138 \uB85C\uB4DC \uC2E4\uD328:', err);
            mainContent.textContent = '';
            const errorDiv = document.createElement('div');
            errorDiv.className = 'view-container';
            const errorP = document.createElement('p');
            errorP.textContent = '\uAC8C\uC2DC\uBB3C\uC744 \uBD88\uB7EC\uC62C \uC218 \uC5C6\uC2B5\uB2C8\uB2E4.';
            errorDiv.appendChild(errorP);
            mainContent.appendChild(errorDiv);
        }
    };

    const showPostForm = async (mode, id) => {
        if (!Auth.isAuthenticated()) {
            Toast.warning('\uB85C\uADF8\uC778\uC774 \uD544\uC694\uD55C \uAE30\uB2A5\uC785\uB2C8\uB2E4.');
            Modal.showLogin();
            return;
        }

        renderTemplate('post-form-template', mainContent);
        const formTitle = document.getElementById('form-title');
        const titleInput = document.getElementById('post-title');
        const contentInput = document.getElementById('post-content');
        const errorEl = document.getElementById('post-error');

        await renderCategoryForm();

        if (mode === 'edit') {
            formTitle.textContent = '\uAE00 \uC218\uC815';
            try {
                const post = await Api.posts.getById(id);
                if (Auth.getUsernameFromToken() !== post.author) {
                    Toast.warning('\uC791\uC131\uC790\uB9CC \uC218\uC815\uD560 \uC218 \uC788\uC2B5\uB2C8\uB2E4.');
                    window.location.hash = '/posts/' + id;
                    return;
                }
                titleInput.value = post.title;
                contentInput.value = post.content;
                const categorySelect = document.getElementById('category-select');
                if (categorySelect) {
                    categorySelect.value = post.category.name;
                }
            } catch (err) {
                errorEl.textContent = '\uAC8C\uC2DC\uBB3C\uC744 \uBD88\uB7EC\uC624\uC9C0 \uBABB\uD588\uC2B5\uB2C8\uB2E4.';
            }
        } else {
            formTitle.textContent = '\uAE00 \uC791\uC131';
        }

        document.getElementById('cancel-btn').onclick = () => { window.history.back(); };

        document.getElementById('post-form').onsubmit = async (e) => {
            e.preventDefault();
            errorEl.textContent = '';

            const categoryInput = document.getElementById('category-select');
            const categoryName = categoryInput.value.trim();

            if (!categoryName) {
                errorEl.textContent = '\uCE74\uD14C\uACE0\uB9AC\uB97C \uC785\uB825\uD558\uC138\uC694.';
                return;
            }

            const payload = {
                title: titleInput.value.trim(),
                content: contentInput.value.trim(),
                category_name: categoryName
            };

            if (!payload.title || !payload.content) {
                errorEl.textContent = '\uC81C\uBAA9/\uB0B4\uC6A9\uC744 \uC785\uB825\uD558\uC138\uC694.';
                return;
            }

            try {
                let result;
                if (mode === 'edit') {
                    result = await Api.posts.update(id, payload);
                } else {
                    result = await Api.posts.create(payload);
                }
                const postId = mode === 'edit' ? id : result.id;
                window.location.hash = '/posts/' + postId;
            } catch (err) {
                errorEl.textContent = err.message || '\uC800\uC7A5 \uC2E4\uD328';
            }
        };
    };

    // Authentication UI update
    const updateAuthStatus = () => {
        const authStatus = document.getElementById('auth-status');
        authStatus.textContent = '';

        if (Auth.isAuthenticated()) {
            const writeBtn = document.createElement('button');
            writeBtn.className = 'btn btn-outline';
            writeBtn.id = 'write-btn';
            writeBtn.textContent = '\uAE00\uC4F0\uAE30';
            writeBtn.addEventListener('click', () => { window.location.hash = '/posts/new'; });

            const logoutBtn = document.createElement('button');
            logoutBtn.className = 'btn btn-primary';
            logoutBtn.id = 'logout-btn';
            logoutBtn.textContent = '\uB85C\uADF8\uC544\uC6C3';
            logoutBtn.addEventListener('click', logout);

            authStatus.appendChild(writeBtn);
            authStatus.appendChild(logoutBtn);
        } else {
            const loginBtn = document.createElement('button');
            loginBtn.className = 'btn btn-primary';
            loginBtn.id = 'login-btn';
            loginBtn.textContent = '\uB85C\uADF8\uC778';
            loginBtn.addEventListener('click', Modal.showLogin);
            authStatus.appendChild(loginBtn);
        }
    };

    // Logout handler
    const logout = () => {
        Auth.clearToken();
        updateAuthStatus();
        window.location.hash = '/';
        Toast.info('\uB85C\uADF8\uC544\uC6C3\uB418\uC5C8\uC2B5\uB2C8\uB2E4.');
    };

    // Login form handler
    const loginForm = document.getElementById('login-form');
    if (loginForm) {
        loginForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            const username = document.getElementById('login-username').value;
            const password = document.getElementById('login-password').value;
            const errorEl = document.getElementById('login-error');

            try {
                const data = await Api.auth.login(username, password);
                Auth.setToken(data.token);
                Modal.closeAll();
                updateAuthStatus();
                window.location.hash = '/';
            } catch (err) {
                errorEl.textContent = err.message || '\uB85C\uADF8\uC778 \uC2E4\uD328';
            }
        });
    }

    // Signup form handler
    const signupForm = document.getElementById('signup-form');
    if (signupForm) {
        signupForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            const username = document.getElementById('signup-username').value;
            const email = document.getElementById('signup-email').value;
            const password = document.getElementById('signup-password').value;
            const errorEl = document.getElementById('signup-error');

            try {
                await Api.auth.signup(username, email, password);
                Toast.success('\uD68C\uC6D0\uAC00\uC785\uC774 \uC644\uB8CC\uB418\uC5C8\uC2B5\uB2C8\uB2E4. \uB85C\uADF8\uC778\uD574\uC8FC\uC138\uC694.');
                Modal.closeAll();
                Modal.showLogin();
            } catch (err) {
                errorEl.textContent = err.message || '\uD68C\uC6D0\uAC00\uC785 \uC2E4\uD328';
            }
        });
    }

    // Blog title click handler
    const blogTitleLink = document.getElementById('blog-title');
    if (blogTitleLink) {
        blogTitleLink.addEventListener('click', (e) => {
            if (State.currentCategory !== '') {
                e.preventDefault();
                window.location.hash = '/';
                loadPostList();
            }
        });
    }

    // Router setup
    const routes = {
        '/': loadPostList,
        '/posts/new': () => showPostForm('create'),
        '/posts/:id': showPostDetail,
        '/posts/:id/edit': (id) => showPostForm('edit', id)
    };

    const handleRoute = () => {
        const path = window.location.hash.slice(1) || '/';

        if (path === '/') {
            routes['/']();
        } else if (path === '/posts/new') {
            routes['/posts/new']();
        } else if (path.match(/^\/posts\/\d+$/)) {
            const id = path.split('/')[2];
            routes['/posts/:id'](id);
        } else if (path.match(/^\/posts\/\d+\/edit$/)) {
            const id = path.split('/')[2];
            routes['/posts/:id/edit'](id);
        }

        updateAuthStatus();
    };

    // Initialize
    window.addEventListener('hashchange', handleRoute);
    handleRoute();
});
