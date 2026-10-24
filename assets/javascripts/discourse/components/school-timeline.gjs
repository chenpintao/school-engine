import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

/**
 * 个人主页「时光」：该用户进入时光胶囊的帖子（精选或高赞，非匿名）。
 * 数据来自 GET /school/timeline/:username，服务端强制排除匿名帖。
 */
export default class SchoolTimeline extends Component {
  @tracked posts = [];
  @tracked loaded = false;

  constructor() {
    super(...arguments);
    const username = this.args.user?.username;
    if (username) {
      ajax(`/school/timeline/${encodeURIComponent(username)}.json`)
        .then((data) => {
          this.posts = data.posts || [];
          this.loaded = true;
        })
        .catch(() => {
          this.posts = [];
          this.loaded = true;
        });
    }
  }

  get showEmpty() {
    return this.loaded && this.posts.length === 0;
  }

  formatDate(iso) {
    if (!iso) return "";
    return new Date(iso).toLocaleDateString("zh-CN", {
      year: "numeric",
      month: "long",
      day: "numeric",
    });
  }

  <template>
    <section class="school-timeline">
      <h3 class="school-timeline-title">
        <span class="school-timeline-dot"></span>
        {{i18n "school_engine.timeline_title"}}
      </h3>

      {{#if this.showEmpty}}
        <p class="school-timeline-empty">{{i18n "school_engine.timeline_empty"}}</p>
      {{/if}}

      <ul class="school-timeline-list">
        {{#each this.posts as |post|}}
          <li class="school-timeline-item">
            <div class="school-timeline-meta">
              <span class="school-timeline-date">{{this.formatDate post.created_at}}</span>
              {{#if post.featured}}
                <span class="school-timeline-badge">★ {{i18n "school_engine.timeline_featured"}}</span>
              {{else}}
                <span class="school-timeline-likes">♡ {{post.like_count}}</span>
              {{/if}}
            </div>
            <a class="school-timeline-excerpt" href={{post.url}}>{{post.excerpt}}</a>
            {{#if post.topic_title}}
              <span class="school-timeline-topic">来自话题：{{post.topic_title}}</span>
            {{/if}}
          </li>
        {{/each}}
      </ul>
    </section>
  </template>
}
