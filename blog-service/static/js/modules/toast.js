// blog-service/static/js/modules/toast.js
// Toast Notification System

const Toast = {
    container: null,

    init() {
        this.container = document.getElementById('toast-container');
        if (!this.container) {
            this.container = document.createElement('div');
            this.container.id = 'toast-container';
            document.body.appendChild(this.container);
        }
    },

    show(message, type = 'info', duration = 3000) {
        if (!this.container) this.init();

        const icons = {
            success: '\u2713',
            error: '\u2715',
            warning: '\u26A0',
            info: '\u2139'
        };

        const titles = {
            success: '성공',
            error: '오류',
            warning: '경고',
            info: '알림'
        };

        const toast = document.createElement('div');
        toast.className = `toast ${type}`;
        
        // Build DOM elements safely
        const iconDiv = document.createElement('div');
        iconDiv.className = 'toast-icon';
        iconDiv.textContent = icons[type] || icons.info;
        
        const contentDiv = document.createElement('div');
        contentDiv.className = 'toast-content';
        
        const titleDiv = document.createElement('div');
        titleDiv.className = 'toast-title';
        titleDiv.textContent = titles[type] || titles.info;
        
        const messageDiv = document.createElement('div');
        messageDiv.className = 'toast-message';
        messageDiv.textContent = message;
        
        contentDiv.appendChild(titleDiv);
        contentDiv.appendChild(messageDiv);
        
        const closeBtn = document.createElement('button');
        closeBtn.className = 'toast-close';
        closeBtn.setAttribute('aria-label', '닫기');
        closeBtn.textContent = '\u00D7';
        closeBtn.addEventListener('click', () => this.hide(toast));
        
        toast.appendChild(iconDiv);
        toast.appendChild(contentDiv);
        toast.appendChild(closeBtn);

        this.container.appendChild(toast);

        if (duration > 0) {
            setTimeout(() => {
                this.hide(toast);
            }, duration);
        }

        return toast;
    },

    hide(toast) {
        toast.classList.add('hiding');
        setTimeout(() => {
            if (toast.parentNode) {
                toast.parentNode.removeChild(toast);
            }
        }, 300);
    },

    success(message, duration) {
        return this.show(message, 'success', duration);
    },

    error(message, duration) {
        return this.show(message, 'error', duration);
    },

    warning(message, duration) {
        return this.show(message, 'warning', duration);
    },

    info(message, duration) {
        return this.show(message, 'info', duration);
    }
};

export default Toast;
