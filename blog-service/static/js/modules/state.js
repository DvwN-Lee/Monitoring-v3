// blog-service/static/js/modules/state.js
// Centralized State Management

const State = {
    currentPage: 1,
    currentCategory: '',
    categoryCounts: {},
    categoriesData: [],
    postsPerPage: 5,

    reset() {
        this.currentPage = 1;
        this.currentCategory = '';
    },

    setCategory(category) {
        this.currentCategory = category;
        this.currentPage = 1;
    },

    setPage(page) {
        this.currentPage = page;
    },

    setCategoriesData(data) {
        this.categoriesData = data;
        this.categoryCounts.all = data.reduce((sum, c) => sum + c.post_count, 0);
        data.forEach(c => {
            this.categoryCounts[c.slug] = c.post_count;
        });
    },

    getCategoryColor(slug) {
        const category = this.categoriesData.find(c => c.slug === slug);
        return category?.color || '#6B7280';
    }
};

export default State;
