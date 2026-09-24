import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { and } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import dIcon from "discourse/helpers/d-icon";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

/**
 * 定制首页（不接管路由、不自绘框架）：组件通过 discovery-above outlet 注入到
 * Discourse 原生 /latest 页面，原生顶栏/侧边栏/移动端框架全部保留；原生话题列表
 * 由 SCSS 在本组件 data-live="true" 时隐藏（body:has(...)，离开 latest 自动恢复）。
 * 结构：欢迎语 + 每日心情签到（5 表情，可改签）/ 精选横条（话题标题 + ≤3 条精选回帖，
 * 右侧点赞数）/ 最新横条（剔除精选话题）。数据 GET /school/feed.json。
 * 所有导入均为插件中已验证模块，样式只用 DC CSS 变量，随主题（含深色）变化。
 */
const MOODS = [
  { value: 1, emoji: "😞" },
  { value: 2, emoji: "😕" },
  { value: 3, emoji: "😐" },
  { value: 4, emoji: "🙂" },
  { value: 5, emoji: "😄" },
];

export default class SchoolHomeFeed extends Component {
  @service router;
  @service currentUser;

  // 构造时即发起加载（无需 DOM 元素），避免依赖 render-modifiers。
  constructor(owner, args) {
    super(owner, args);
    this.load();
  }

  @tracked loaded = false;
  @tracked featured = [];
  @tracked latest = [];
  @tracked todayMood = null;
  @tracked moodEnabled = true;
  @tracked editing = false;

  get onLatest() {
    return this.router.currentRouteName === "discovery.latest";
  }

  get isLive() {
    return this.onLatest && this.loaded;
  }

  get greeting() {
    return this.currentUser
      ? i18n("school_engine.welcome_back", {
          name: this.currentUser.display_name || this.currentUser.username,
        })
      : i18n("school_engine.welcome_guest");
  }

  moods = MOODS;

  get currentMood() {
    return MOODS.find((m) => m.value === this.todayMood);
  }

  get currentMoodName() {
    return this.todayMood
      ? i18n(`school_engine.mood_name_${this.todayMood}`)
      : "";
  }

  get showPicker() {
    return !this.todayMood || this.editing;
  }

  moodLabel = (value) => i18n(`school_engine.mood_name_${value}`);

  get featuredTopicIds() {
    return new Set(this.featured.map((card) => card.topic_id));
  }

  get latestFiltered() {
    return this.latest.filter(
      (card) => !this.featuredTopicIds.has(card.topic_id),
    );
  }

  load() {
    if (!this.onLatest) {
      this.loaded = true;
      return;
    }
    ajax("/school/feed.json")
      .then((data) => {
        this.featured = data.featured || [];
        this.latest = data.latest || [];
        this.todayMood = data.today_mood;
        this.moodEnabled = data.mood_enabled !== false;
        this.loaded = true;
      })
      .catch(popupAjaxError)
      .finally(() => {
        this.loaded = true;
      });
  }

  @action
  selectMood(mood) {
    ajax("/school/mood-checkin.json", { type: "POST", data: { mood } })
      .then((data) => {
        this.todayMood = data.mood;
        this.editing = false;
      })
      .catch(popupAjaxError);
  }

  @action
  startEdit() {
    this.editing = true;
  }

  <template>
    <div
      class="school-home"
      data-live={{if this.isLive "true" "false"}}
    >
      <header class="school-home-header">
        <h1 class="school-home-greeting">{{this.greeting}}</h1>
        {{#if (and this.currentUser this.moodEnabled)}}
          <div class="school-mood-checkin">
            {{#if this.showPicker}}
              <span class="school-mood-checkin-label">
                {{i18n "school_engine.mood_today"}}
              </span>
              <div class="school-mood-picker" role="group">
                {{#each this.moods as |mood|}}
                  <button
                    type="button"
                    class="school-mood-btn"
                    title={{fn this.moodLabel mood.value}}
                    aria-label={{fn this.moodLabel mood.value}}
                    {{on "click" (fn this.selectMood mood.value)}}
                  >
                    {{mood.emoji}}
                  </button>
                {{/each}}
              </div>
            {{else}}
              <span
                class="school-mood-current"
                title={{this.currentMoodName}}
              >
                {{this.currentMood.emoji}}
              </span>
              <DButton
                @action={{this.startEdit}}
                @icon="pencil-alt"
                @label="school_engine.mood_change"
                class="btn-small school-mood-change-btn"
              />
            {{/if}}
          </div>
        {{/if}}
      </header>

      {{#if this.featured.length}}
        <section class="school-feed-section">
          <h2 class="school-feed-heading">
            {{i18n "school_engine.feed_featured_title"}}
          </h2>
          {{#each this.featured as |card|}}
            <article class="school-feed-card">
              <a class="school-feed-title" href={{card.url}}>{{card.title}}</a>
              <ul class="school-feed-replies">
                {{#each card.replies as |reply|}}
                  <li class="school-feed-reply">
                    <a class="school-feed-excerpt" href={{reply.url}}>
                      {{reply.excerpt}}
                    </a>
                    <span class="school-feed-likes">
                      {{dIcon "d-liked"}}
                      {{reply.like_count}}
                    </span>
                  </li>
                {{/each}}
              </ul>
            </article>
          {{/each}}
        </section>
      {{/if}}

      {{#if this.latestFiltered.length}}
        <section class="school-feed-section">
          <h2 class="school-feed-heading">
            {{i18n "school_engine.feed_latest_title"}}
          </h2>
          {{#each this.latestFiltered as |card|}}
            <article class="school-feed-card school-feed-card-plain">
              <a class="school-feed-title" href={{card.url}}>{{card.title}}</a>
              <span class="school-feed-likes">
                {{dIcon "d-liked"}}
                {{card.like_count}}
              </span>
            </article>
          {{/each}}
        </section>
      {{/if}}
    </div>
  </template>
}
