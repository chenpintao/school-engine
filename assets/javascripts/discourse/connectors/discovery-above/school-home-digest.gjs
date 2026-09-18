import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";
import { didInsert } from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import dIcon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";

/**
 * 原生首页（discovery /latest）顶部的「今日话题 + 精选回答」区块。
 * 不接管 "/"、不自绘页面框架——侧边栏、顶部导航、话题列表全部沿用 Discourse 原生，
 * 本组件只通过 discovery-above outlet（每个 discovery 页面只渲染一次，不会随
 * 无限滚动/翻页重复挂载）注入到列表上方；数据来自 GET /school/home.json。
 * 另加模块级单实例保护：任何情况下同屏只允许一个区块渲染，防止 outlet 行为变化导致堆叠。
 * 仅用核心已验证模块（ajax / i18n / render-modifiers），样式只引用 DC CSS 变量。
 */
let liveDigestCount = 0;

export default class SchoolHomeDigest extends Component {
  @service router;
  isCounted = false;
  @tracked isLive = false;
  @tracked dailyTopic = null;
  @tracked featuredPosts = [];
  @tracked fallback = false;
  @tracked loaded = false;

  get onLatest() {
    return this.router.currentRouteName === "discovery.latest";
  }

  get showBlock() {
    return (
      this.isLive &&
      this.onLatest &&
      this.loaded &&
      (this.dailyTopic || this.featuredPosts.length > 0)
    );
  }

  load() {
    // 只放行第一个挂载的实例；重复 outlet 实例静默不渲染，避免首页区块堆叠
    liveDigestCount += 1;
    this.isCounted = true;
    if (liveDigestCount !== 1 || !this.onLatest) {
      return;
    }
    this.isLive = true;
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

  willDestroy() {
    super.willDestroy(...arguments);
    if (this.isCounted) {
      liveDigestCount = Math.max(0, liveDigestCount - 1);
    }
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
                {{dIcon "chevron-right"}}
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
                        {{dIcon (if post.anonymous "far-eye-slash" "user")}}
                        {{post.author_name}}
                      </span>
                      {{#if post.like_count}}
                        <span class="school-digest-item-likes">
                          {{dIcon "d-liked"}}
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
