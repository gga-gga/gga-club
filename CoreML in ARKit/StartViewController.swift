import UIKit

final class StartViewController: UIViewController {

    @IBOutlet weak var startButton: UIButton!  // Storyboard で接続

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    
    @IBAction func onTapStart(_ sender: UIButton) {
            // 何もしなくてOK
            // Storyboard でボタンに直接 segue をつないでおけば、
            // 押した瞬間に自動で画面遷移が走ります
        }
}
