// blog-service/static/js/modules/api.js
// API Client Abstraction

import { getToken, authHeader } from './auth.js';

const API_BASE = '';

export const Api = {
    async get(endpoint) {
        const res = await fetch(`${API_BASE}${endpoint}`);
        if (!res.ok) {
            const error = await res.json().catch(() => ({}));
            throw new Error(error.message || error.detail || 'Request failed');
        }
        return res.json();
    },

    async post(endpoint, data, authenticated = false) {
        const headers = { 'Content-Type': 'application/json' };
        if (authenticated) {
            Object.assign(headers, authHeader());
        }

        const res = await fetch(`${API_BASE}${endpoint}`, {
            method: 'POST',
            headers,
            body: JSON.stringify(data)
        });

        const responseData = await res.json().catch(() => ({}));
        if (!res.ok) {
            throw new Error(responseData.message || responseData.detail || responseData.error || 'Request failed');
        }
        return responseData;
    },

    async patch(endpoint, data, authenticated = false) {
        const headers = { 'Content-Type': 'application/json' };
        if (authenticated) {
            Object.assign(headers, authHeader());
        }

        const res = await fetch(`${API_BASE}${endpoint}`, {
            method: 'PATCH',
            headers,
            body: JSON.stringify(data)
        });

        const responseData = await res.json().catch(() => ({}));
        if (!res.ok) {
            throw new Error(responseData.message || responseData.detail || responseData.error || 'Request failed');
        }
        return responseData;
    },

    async delete(endpoint, authenticated = false) {
        const headers = {};
        if (authenticated) {
            Object.assign(headers, authHeader());
        }

        const res = await fetch(`${API_BASE}${endpoint}`, {
            method: 'DELETE',
            headers
        });

        if (!res.ok && res.status !== 204) {
            const error = await res.json().catch(() => ({}));
            throw new Error(error.message || error.detail || 'Request failed');
        }
        return res.status === 204 ? null : res.json();
    },

    // Blog API endpoints
    posts: {
        getAll(category = null) {
            const url = category ? `/blog/api/posts?category=${category}` : '/blog/api/posts';
            return Api.get(url);
        },
        getById(id) {
            return Api.get(`/blog/api/posts/${id}`);
        },
        create(data) {
            return Api.post('/blog/api/posts', data, true);
        },
        update(id, data) {
            return Api.patch(`/blog/api/posts/${id}`, data, true);
        },
        delete(id) {
            return Api.delete(`/blog/api/posts/${id}`, true);
        }
    },

    categories: {
        getAll() {
            return Api.get('/blog/api/categories');
        }
    },

    auth: {
        login(username, password) {
            return Api.post('/api/login', { username, password });
        },
        signup(username, email, password) {
            return Api.post('/api/users', { username, email, password });
        }
    }
};

export default Api;
