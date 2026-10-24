import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import dIcon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";

// 首页精选区块：仅挂在全局 /latest（无分类、无标签）之上，
// 展示最多 N 个精选话题（后台 school_engine_featured_topics 可配，默认 1），
// 每个话题最多 3 条精选内容。原生列表逻辑完全不动。
export default class SchoolFeatured extends Component {
  constructor(owner, args) {
    super(owner, args);
    this.load();
  }

  @tracked topics = [];
  @tracked expanded = false;

  get isLatest() {
    const model = this.args.model;
    return !this.args.category && !this.args.tag && model?.list?.filter === "latest";
  }

  get showToggle() {
    return this.topics.some((t) => (t.replies ?? []).length > 1);
  }

  load() {
    ajax("/school/featured.json")
      .then((data) => {
        this.topics = data.topics || [];
      })
      .catch(() => {});
  }

  @action
  toggleExpanded() {
    this.expanded = !this.expanded;
  }

  <template>
    {{#if this.isLatest}}
      {{#if this.topics.length}}
        <section class={{if this.expanded "school-featured is-expanded" "school-featured"}}>
          <h2 class="school-featured-heading">
            <span class="school-featured-badge">
              {{dIcon "star"}}
              {{i18n "school_engine.featured_label"}}
            </span>
          </h2>
          {{#each this.topics as |t|}}
            <a class="school-featured-title" href={{t.url}}>{{t.title}}</a>
            <ul class="school-featured-replies">
              {{#each t.replies as |reply|}}
                <li class="school-featured-reply">
                  <a class="school-featured-reply-link" href={{reply.url}}>
                    <span class="school-featured-reply-excerpt">{{reply.excerpt}}</span>
                    <span class="school-featured-reply-likes">
                      {{dIcon "heart"}}
                      <span>{{reply.like_count}}</span>
                    </span>
                  </a>
                </li>
              {{/each}}
            </ul>
          {{/each}}
          {{#if this.showToggle}}
            <button
              type="button"
              class="school-featured-toggle"
              {{on "click" this.toggleExpanded}}
            >
              {{if this.expanded
                (i18n "school_engine.featured_collapse")
                (i18n "school_engine.featured_expand")}}
              {{dIcon (if this.expanded "chevron-up" "chevron-down")}}
            </button>
          {{/if}}
        </section>
      {{/if}}
    {{/if}}
  </template>
}
