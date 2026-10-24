import Component from "@glimmer/component";
import SchoolMoodHeatmap from "../../components/school-mood-heatmap";

/**
 * 个人主页注入「心情记录」热力图（user-profile-primary outlet，2026.x
 * 已无旧的 user-profile outlet）。
 * outlet model 为 User 对象，兼容历史 UserProfile（其 .user 为用户对象）。
 */
export default class SchoolMoodHeatmapConnector extends Component {
  get user() {
    const model = this.args.outletArgs?.model;
    return model?.user || model;
  }

  <template>
    <SchoolMoodHeatmap @user={{this.user}} />
  </template>
}
