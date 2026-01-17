// blog-service/static/js/modules/utils.js
// Utility Functions

export const hexToRgb = (hex) => {
    const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
    return result
        ? `${parseInt(result[1], 16)}, ${parseInt(result[2], 16)}, ${parseInt(result[3], 16)}`
        : '107, 114, 128';
};

export const renderTemplate = (templateId, container) => {
    const mainContent = container || document.getElementById('main-content');
    const template = document.getElementById(templateId);
    if (template) {
        mainContent.innerHTML = '';
        mainContent.appendChild(template.content.cloneNode(true));
    }
};

export const escapeHtml = (text) => {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
};

export default {
    hexToRgb,
    renderTemplate,
    escapeHtml
};
