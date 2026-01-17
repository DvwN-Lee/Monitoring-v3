// blog-service/static/js/modules/modal.js
// Modal Management

const Modal = {
    init() {
        // Close modal when clicking outside
        window.addEventListener('click', (e) => {
            if (e.target.classList.contains('modal')) {
                this.closeAll();
            }
        });

        // Setup close buttons
        document.getElementById('close-login')?.addEventListener('click', () => this.closeAll());
        document.getElementById('close-signup')?.addEventListener('click', () => this.closeAll());

        // Setup navigation between modals
        document.getElementById('go-to-signup')?.addEventListener('click', () => this.show('signup'));
        document.getElementById('go-to-login')?.addEventListener('click', () => this.show('login'));
    },

    show(type) {
        this.closeAll();
        const modal = document.getElementById(`${type}-modal`);
        if (modal) {
            modal.classList.add('active');
        }
    },

    closeAll() {
        document.querySelectorAll('.modal').forEach(m => m.classList.remove('active'));
    },

    showLogin() {
        this.show('login');
    },

    showSignup() {
        this.show('signup');
    }
};

export default Modal;
