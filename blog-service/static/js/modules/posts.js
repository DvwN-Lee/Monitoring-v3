// blog-service/static/js/modules/posts.js
// Post UI Logic

import State from './state.js';
import Api from './api.js';
import Toast from './toast.js';
import { hexToRgb } from './utils.js';

export const renderPosts = (allPosts) => {
    const container = document.getElementById('posts-container');
    const start = (State.currentPage - 1) * State.postsPerPage;
    const end = start + State.postsPerPage;
    const posts = allPosts.slice(start, end);

    container.textContent = '';
    if (posts.length === 0) {
        const emptyMsg = document.createElement('p');
        emptyMsg.style.cssText = 'text-align:center;color:#777;padding:40px;';
        emptyMsg.textContent = '\uAC8C\uC2DC\uBB3C\uC774 \uC5C6\uC2B5\uB2C8\uB2E4.';
        container.appendChild(emptyMsg);
        renderPagination(0);
        return;
    }

    posts.forEach(post => {
        const li = document.createElement('li');
        li.className = 'post-list-item';
        li.onclick = () => { window.location.hash = '/posts/' + post.id; };

        const categoryColor = State.getCategoryColor(post.category.slug);
        const categoryColorRgb = hexToRgb(categoryColor);

        const header = document.createElement('div');
        header.className = 'post-list-header';

        const titleDiv = document.createElement('div');
        titleDiv.className = 'post-title';
        titleDiv.appendChild(document.createTextNode(post.title + ' '));

        const badge = document.createElement('span');
        badge.className = 'category-badge';
        badge.style.setProperty('--category-color', categoryColor);
        badge.style.setProperty('--category-color-rgb', categoryColorRgb);
        badge.textContent = post.category.name;
        titleDiv.appendChild(badge);

        const authorSpan = document.createElement('span');
        authorSpan.className = 'post-author';
        authorSpan.textContent = 'by ' + post.author;

        header.appendChild(titleDiv);
        header.appendChild(authorSpan);

        const excerpt = document.createElement('div');
        excerpt.className = 'post-excerpt';
        excerpt.textContent = post.excerpt || '';

        li.appendChild(header);
        li.appendChild(excerpt);
        container.appendChild(li);
    });

    renderPagination(allPosts.length);
};

export const renderPagination = (totalPosts) => {
    const totalPages = Math.ceil(totalPosts / State.postsPerPage);
    const pageNumbersContainer = document.getElementById('page-numbers');
    pageNumbersContainer.textContent = '';

    const prevBtn = document.getElementById('prev-btn');
    prevBtn.disabled = State.currentPage === 1;
    prevBtn.onclick = () => {
        if (State.currentPage > 1) {
            State.setPage(State.currentPage - 1);
            loadPosts();
        }
    };

    const startPage = Math.floor((State.currentPage - 1) / 10) * 10 + 1;
    const endPage = Math.min(startPage + 9, totalPages);

    for (let i = startPage; i <= endPage; i++) {
        const btn = document.createElement('button');
        btn.className = 'page-number' + (i === State.currentPage ? ' active' : '');
        btn.textContent = i;
        btn.onclick = ((page) => () => {
            State.setPage(page);
            loadPosts();
        })(i);
        pageNumbersContainer.appendChild(btn);
    }

    const nextBtn = document.getElementById('next-btn');
    nextBtn.disabled = State.currentPage >= totalPages;
    nextBtn.onclick = () => {
        if (State.currentPage < totalPages) {
            State.setPage(State.currentPage + 1);
            loadPosts();
        }
    };
};

export const showLoading = (container) => {
    const loadingDiv = document.createElement('div');
    loadingDiv.className = 'loading-overlay';

    const inner = document.createElement('div');
    const spinner = document.createElement('div');
    spinner.className = 'loading-spinner';
    const text = document.createElement('div');
    text.className = 'loading-text';
    text.textContent = '\uB85C\uB529 \uC911...';
    inner.appendChild(spinner);
    inner.appendChild(text);
    loadingDiv.appendChild(inner);

    container.style.position = 'relative';
    container.appendChild(loadingDiv);
    return loadingDiv;
};

export const hideLoading = (loadingDiv) => {
    if (loadingDiv && loadingDiv.parentNode) {
        loadingDiv.parentNode.removeChild(loadingDiv);
    }
};

export const loadPosts = async () => {
    const container = document.getElementById('posts-container');
    const loadingDiv = showLoading(container.parentNode);

    try {
        const posts = await Api.posts.getAll(State.currentCategory || null);
        renderPosts(posts);
    } catch (err) {
        console.error('\uAC8C\uC2DC\uBB3C \uB85C\uB4DC \uC2E4\uD328:', err);
        container.textContent = '';
        const errorMsg = document.createElement('p');
        errorMsg.textContent = '\uAC8C\uC2DC\uBB3C\uC744 \uBD88\uB7EC\uC624\uB294 \uB370 \uC2E4\uD328\uD588\uC2B5\uB2C8\uB2E4.';
        container.appendChild(errorMsg);
        Toast.error('\uAC8C\uC2DC\uBB3C\uC744 \uBD88\uB7EC\uC624\uB294 \uB370 \uC2E4\uD328\uD588\uC2B5\uB2C8\uB2E4.');
    } finally {
        hideLoading(loadingDiv);
    }
};

export default {
    renderPosts,
    renderPagination,
    showLoading,
    hideLoading,
    loadPosts
};
