// blog-service/static/js/modules/auth.js
// Authentication Utilities

export const getToken = () => sessionStorage.getItem('authToken') || '';

export const setToken = (token) => sessionStorage.setItem('authToken', token);

export const clearToken = () => sessionStorage.removeItem('authToken');

export const parseJwt = (token) => {
    try {
        const base = token.split('.')[1];
        const b = atob(base.replace(/-/g, '+').replace(/_/g, '/'));
        return JSON.parse(b);
    } catch {
        return null;
    }
};

export const getUsernameFromToken = () => {
    const token = getToken();
    if (!token) return '';

    // Local test token handling
    if (token.startsWith('session-token-for-')) {
        return token.replace('session-token-for-', '');
    }

    // JWT token handling
    const payload = parseJwt(token);
    return (payload && payload.username) ? payload.username : '';
};

export const authHeader = () => ({ 'Authorization': `Bearer ${getToken()}` });

export const isAuthenticated = () => !!getToken();

export const canEdit = (author) => {
    return isAuthenticated() && getUsernameFromToken() === author;
};

const Auth = {
    getToken,
    setToken,
    clearToken,
    parseJwt,
    getUsernameFromToken,
    authHeader,
    isAuthenticated,
    canEdit
};

export default Auth;
