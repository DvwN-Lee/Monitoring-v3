// blog-service/static/js/modules/categories.js
// Category UI Logic

import State from './state.js';
import Api from './api.js';
import { loadPosts } from './posts.js';
import { hexToRgb } from './utils.js';

export const loadCategoryCounts = async () => {
    try {
        const cats = await Api.categories.getAll();
        State.setCategoriesData(cats);
        renderCategoryTabs();
    } catch (err) {
        console.error('\uCE74\uD14C\uACE0\uB9AC \uCE74\uC6B4\uD2B8 \uB85C\uB4DC \uC2E4\uD328:', err);
    }
};

export const renderCategoryTabs = () => {
    const categoryFilter = document.querySelector('.category-filter');
    if (!categoryFilter) return;

    categoryFilter.textContent = '';

    // All tab
    const allTab = document.createElement('button');
    allTab.className = 'category-tab' + (State.currentCategory === '' ? ' active' : '');
    allTab.setAttribute('data-category', '');
    allTab.setAttribute('role', 'tab');
    allTab.setAttribute('aria-selected', State.currentCategory === '' ? 'true' : 'false');
    allTab.setAttribute('aria-controls', 'posts-container');

    allTab.appendChild(document.createTextNode('\uC804\uCCB4 '));
    const allCount = document.createElement('span');
    allCount.className = 'post-count';
    allCount.textContent = '(' + (State.categoryCounts.all || 0) + ')';
    allTab.appendChild(allCount);
    categoryFilter.appendChild(allTab);

    // Dynamic category tabs
    State.categoriesData.forEach(cat => {
        const tab = document.createElement('button');
        tab.className = 'category-tab' + (State.currentCategory === cat.slug ? ' active' : '');
        tab.setAttribute('data-category', cat.slug);
        tab.setAttribute('role', 'tab');
        tab.setAttribute('aria-selected', State.currentCategory === cat.slug ? 'true' : 'false');
        tab.setAttribute('aria-controls', 'posts-container');

        tab.appendChild(document.createTextNode(cat.name + ' '));
        const catCount = document.createElement('span');
        catCount.className = 'post-count';
        catCount.textContent = '(' + (cat.post_count || 0) + ')';
        tab.appendChild(catCount);

        if (cat.color) {
            tab.style.setProperty('--category-color', cat.color);
            tab.style.setProperty('--category-color-rgb', hexToRgb(cat.color));
        }

        categoryFilter.appendChild(tab);
    });

    setupCategoryTabs();
};

export const setupCategoryTabs = () => {
    const tabs = document.querySelectorAll('.category-tab');

    tabs.forEach(tab => {
        const category = tab.getAttribute('data-category') || '';

        if (category === (State.currentCategory || '')) {
            tab.classList.add('active');
            tab.setAttribute('aria-selected', 'true');
        } else {
            tab.classList.remove('active');
            tab.setAttribute('aria-selected', 'false');
        }

        tab.onclick = async () => {
            if (category === State.currentCategory) return;

            State.setCategory(category);

            tabs.forEach(t => {
                t.classList.remove('active');
                t.setAttribute('aria-selected', 'false');
            });
            tab.classList.add('active');
            tab.setAttribute('aria-selected', 'true');

            await loadPosts();
        };
    });
};

export const renderCategoryForm = async () => {
    if (State.categoriesData.length === 0) {
        try {
            const cats = await Api.categories.getAll();
            State.setCategoriesData(cats);
        } catch (err) {
            console.error('\uCE74\uD14C\uACE0\uB9AC \uB85C\uB4DC \uC2E4\uD328:', err);
        }
    }

    const radioGroup = document.querySelector('.radio-group');
    if (!radioGroup) return;

    radioGroup.textContent = '';

    const input = document.createElement('input');
    input.type = 'text';
    input.id = 'category-select';
    input.setAttribute('list', 'categories-datalist');
    input.placeholder = '\uCE74\uD14C\uACE0\uB9AC\uB97C \uC120\uD0DD\uD558\uAC70\uB098 \uC785\uB825\uD558\uC138\uC694';
    input.required = true;
    input.maxLength = 50;
    input.autocomplete = 'off';

    const datalist = document.createElement('datalist');
    datalist.id = 'categories-datalist';
    State.categoriesData.forEach(cat => {
        const option = document.createElement('option');
        option.value = cat.name;
        datalist.appendChild(option);
    });

    radioGroup.appendChild(input);
    radioGroup.appendChild(datalist);
};

export default {
    loadCategoryCounts,
    renderCategoryTabs,
    setupCategoryTabs,
    renderCategoryForm
};
