import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";
import { didInsert } from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

/**
 * 原生首页（discovery /latest）顶部的「今日话题 + 精选回答」区块。
 * 不接管 "/"、不自绘页面框架——侧边栏、顶部导航、话题列表全部沿用 Discourse 原生，
 * 本组件只通过 above-discovery-list-container outlet 注入到原生列表上方；
 * 数据来自 GET /school/home.json。仅用核心已验证模块（ajax / i18n / render-modifiers），
 * 样式只引用 DC CSS 变量，避免任何未验证的新模块导入拖垮整个插件 bundle。
 */
export default class SchoolHomeDigest extends Component {
  @service router;
  @tracked dailyTopic = null;
  @tracked featuredPosts = [];
  @tracked fallback = false;
  @tracked loaded = false;

  get onLatest() {
    return this.router.currentRouteName === "discovery.latest";
  }

  get showBlock() {
    return (
      this.onLatest &&
      this.loaded &&
      (this.dailyTopic || this.featuredPosts.length > 0)
    );
  }

  load() {
    if (!this.onLatest) {
      return;
    }
    ajax("/school/home.json")
      .then((data) => {
        this.dailyTopic = data.daily_topic;
        this.featuredPosts = data.featured_posts || [];
        this.fallback = data.fallback === true;
        this.loaded = true;
      })
      .catch(() => {
        // 首页区块失败不影响原生 latest 列表
        this.loaded = true;
      });
  }

  <template>
    <div {{didInsert this.load}}>
      {{#if this.showBlock}}
        <div class="school-home-digest">
          {{#if this.dailyTopic}}
            <section class="school-digest-section school-digest-topic">
              <h2 class="school-digest-heading">
                {{i18n "school_engine.home_daily_title"}}
              </h2>
              <h3 class="school-digest-topic-title">
                <a href={{this.dailyTopic.url}}>{{this.dailyTopic.title}}</a>
              </h3>
              {{#if this.dailyTopic.excerpt}}
                <p class="school-digest-topic-excerpt">{{this.dailyTopic.excerpt}}</p>
              {{/if}}
              <a class="school-digest-topic-join" href={{this.dailyTopic.url}}>
                {{i18n "school_engine.home_daily_join"}}
                {{d-icon "chevron-right"}}
              </a>
            </section>
          {{/if}}

          {{#if this.featuredPosts.length}}
            <section class="school-digest-section school-digest-featured">
              <h2 class="school-digest-heading">
                {{i18n "school_engine.home_featured_title"}}
              </h2>
              {{#if this.fallback}}
                <p class="school-digest-fallback">{{i18n "school_engine.home_featured_fallback"}}</p>
              {{/if}}
              <ul class="school-digest-list">
                {{#each this.featuredPosts as |post|}}
                  <li class="school-digest-item">
                    <div class="school-digest-item-meta">
                      <span class="school-digest-item-author">
                        {{d-icon (if post.anonymous "far-eye-slash" "user")}}
                        {{post.author_name}}
                      </span>
                      {{#if post.like_count}}
                        <span class="school-digest-item-likes">
                          {{d-icon "d-liked"}}
                          {{post.like_count}}
                        </span>
                      {{/if}}
                    </div>
                    <a class="school-digest-item-excerpt" href={{post.url}}>{{post.excerpt}}</a>
                  </li>
                {{/each}}
              </ul>
            </section>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
